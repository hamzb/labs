#!/usr/bin/env python3
# Generates concurrent, independent order-processing transactions on the primary.

from __future__ import annotations

import argparse
import json
import math
import os
import queue
import sys
import threading
import time
from dataclasses import dataclass, field

import pymysql


UPDATE_ORDER = """
UPDATE orders
SET status_code = MOD(status_code + 1, 5),
    version = version + 1
WHERE order_id = %s
"""


@dataclass
class WorkerStats:
    committed: int = 0
    updated_rows: int = 0
    errors: int = 0
    latencies_ms: list[float] = field(default_factory=list)
    error_messages: list[str] = field(default_factory=list)


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be greater than zero")
    return parsed


def positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be greater than zero")
    return parsed


def required_environment(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} must be set to a non-empty value")
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run concurrent transactions against independent order ranges."
    )
    parser.add_argument("--concurrency", type=positive_int, default=16)
    run_limit = parser.add_mutually_exclusive_group()
    run_limit.add_argument("--duration", type=positive_float)
    run_limit.add_argument("--transactions", type=positive_int)
    parser.add_argument("--order-count", type=positive_int, default=100000)
    parser.add_argument("--updates-per-transaction", type=positive_int, default=1)
    parser.add_argument("--report-interval", type=positive_float, default=1.0)
    parser.add_argument(
        "--mode", choices=("independent", "hotspot"), default="independent"
    )
    parser.add_argument("--hotspot-size", type=positive_int, default=16)
    args = parser.parse_args()
    if args.duration is None and args.transactions is None:
        args.duration = 30.0
    return args


def connect() -> pymysql.Connection:
    return pymysql.connect(
        host=os.environ.get("MYSQL_HOST", "primary"),
        port=int(os.environ.get("MYSQL_PORT", "3306")),
        user=required_environment("MYSQL_APP_USER"),
        password=required_environment("MYSQL_APP_PASSWORD"),
        database="order_management",
        autocommit=False,
        connect_timeout=10,
        read_timeout=30,
        write_timeout=30,
        charset="utf8mb4",
    )


def order_ids_for_transaction(
    worker_id: int,
    transaction_index: int,
    args: argparse.Namespace,
) -> list[int]:
    if args.mode == "hotspot":
        first_offset = transaction_index * args.updates_per_transaction + worker_id
        return [
            1 + ((first_offset + offset) % args.hotspot_size)
            for offset in range(args.updates_per_transaction)
        ]

    partition_start = (worker_id * args.order_count) // args.concurrency + 1
    partition_end = ((worker_id + 1) * args.order_count) // args.concurrency
    partition_size = partition_end - partition_start + 1
    first_offset = transaction_index * args.updates_per_transaction
    return [
        partition_start + ((first_offset + offset) % partition_size)
        for offset in range(args.updates_per_transaction)
    ]


def transaction_target_for_worker(
    worker_id: int,
    total_transactions: int,
    concurrency: int,
) -> int:
    base_target, remainder = divmod(total_transactions, concurrency)
    return base_target + (1 if worker_id < remainder else 0)


def run_worker(
    worker_id: int,
    args: argparse.Namespace,
    stats: WorkerStats,
    ready: queue.Queue[tuple[int, str | None]],
    start_event: threading.Event,
    stop_event: threading.Event,
    deadline: list[float],
) -> None:
    connection: pymysql.Connection | None = None
    ready_reported = False

    try:
        connection = connect()
        cursor = connection.cursor()
        ready.put((worker_id, None))
        ready_reported = True
        start_event.wait()

        if stop_event.is_set():
            return

        transaction_index = 0
        transaction_target = (
            transaction_target_for_worker(
                worker_id, args.transactions, args.concurrency
            )
            if args.transactions is not None
            else None
        )

        while not stop_event.is_set():
            if transaction_target is not None:
                if transaction_index >= transaction_target:
                    break
            elif time.monotonic() >= deadline[0]:
                break

            order_ids = order_ids_for_transaction(worker_id, transaction_index, args)
            started = time.perf_counter()

            try:
                affected_rows = cursor.executemany(
                    UPDATE_ORDER, [(order_id,) for order_id in order_ids]
                )
                if affected_rows != len(order_ids):
                    raise RuntimeError(
                        f"expected {len(order_ids)} updated rows, got {affected_rows}"
                    )
                connection.commit()
                stats.committed += 1
                stats.updated_rows += affected_rows
                stats.latencies_ms.append((time.perf_counter() - started) * 1000)
            except Exception as error:  # Keep the run alive long enough to report failures.
                connection.rollback()
                stats.errors += 1
                if len(stats.error_messages) < 3:
                    stats.error_messages.append(str(error))

            transaction_index += 1
    except Exception as error:
        stats.errors += 1
        stats.error_messages.append(str(error))
        if not ready_reported:
            ready.put((worker_id, str(error)))
    finally:
        if connection is not None:
            connection.close()


def percentile(sorted_values: list[float], percentile_value: float) -> float:
    if not sorted_values:
        return 0.0
    index = max(0, math.ceil((percentile_value / 100) * len(sorted_values)) - 1)
    return sorted_values[index]


def validate_dataset(args: argparse.Namespace) -> None:
    with connect() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT COUNT(*) FROM orders")
            actual_order_count = int(cursor.fetchone()[0])

    if actual_order_count != args.order_count:
        raise RuntimeError(
            f"expected {args.order_count} orders, found {actual_order_count}; "
            "run ./scripts/setup/init-workload.sh with matching arguments"
        )

    smallest_partition = args.order_count // args.concurrency
    if smallest_partition < args.updates_per_transaction:
        raise RuntimeError(
            "each worker needs at least as many orders as updates per transaction"
        )
    if args.hotspot_size > args.order_count:
        raise RuntimeError("hotspot size cannot exceed the order count")


def main() -> int:
    args = parse_args()

    try:
        validate_dataset(args)
    except Exception as error:
        print(f"Workload validation failed: {error}", file=sys.stderr)
        return 1

    run_limit = (
        f"transactions={args.transactions}"
        if args.transactions is not None
        else f"duration={args.duration:.1f}s"
    )
    print(
        "Starting workload: "
        f"mode={args.mode} concurrency={args.concurrency} "
        f"{run_limit} orders={args.order_count} "
        f"updates_per_transaction={args.updates_per_transaction}"
    )

    worker_stats = [WorkerStats() for _ in range(args.concurrency)]
    ready: queue.Queue[tuple[int, str | None]] = queue.Queue()
    start_event = threading.Event()
    stop_event = threading.Event()
    deadline = [0.0]
    threads = [
        threading.Thread(
            target=run_worker,
            name=f"worker-{worker_id}",
            args=(
                worker_id,
                args,
                worker_stats[worker_id],
                ready,
                start_event,
                stop_event,
                deadline,
            ),
        )
        for worker_id in range(args.concurrency)
    ]

    for thread in threads:
        thread.start()

    startup_errors = []
    try:
        for _ in threads:
            worker_id, error = ready.get(timeout=30)
            if error:
                startup_errors.append(f"worker {worker_id}: {error}")
    except queue.Empty:
        startup_errors.append("workers did not establish database connections in time")

    if startup_errors:
        stop_event.set()
        start_event.set()
        for thread in threads:
            thread.join(timeout=5)
        for error in startup_errors:
            print(error, file=sys.stderr)
        return 1

    started_at = time.monotonic()
    deadline[0] = (
        started_at + args.duration if args.duration is not None else math.inf
    )
    start_event.set()
    previous_committed = 0
    previous_report = started_at

    while any(thread.is_alive() for thread in threads):
        time.sleep(min(0.2, args.report_interval))
        now = time.monotonic()
        if now - previous_report < args.report_interval and now < deadline[0]:
            continue

        committed = sum(item.committed for item in worker_stats)
        interval = max(now - previous_report, 0.001)
        interval_tps = (committed - previous_committed) / interval
        elapsed = now - started_at
        errors = sum(item.errors for item in worker_stats)
        print(
            f"elapsed={elapsed:6.1f}s committed={committed:8d} "
            f"interval_tps={interval_tps:8.1f} errors={errors}"
        )
        previous_committed = committed
        previous_report = now

    for thread in threads:
        thread.join()

    elapsed = max(time.monotonic() - started_at, 0.001)
    committed = sum(item.committed for item in worker_stats)
    updated_rows = sum(item.updated_rows for item in worker_stats)
    errors = sum(item.errors for item in worker_stats)
    latencies = sorted(
        latency
        for item in worker_stats
        for latency in item.latencies_ms
    )
    error_messages = [
        message
        for item in worker_stats
        for message in item.error_messages
    ][:10]

    result = {
        "mode": args.mode,
        "concurrency": args.concurrency,
        "target_transactions": args.transactions,
        "duration_seconds": round(elapsed, 3),
        "committed_transactions": committed,
        "updated_rows": updated_rows,
        "errors": errors,
        "transactions_per_second": round(committed / elapsed, 2),
        "latency_ms_p50": round(percentile(latencies, 50), 3),
        "latency_ms_p95": round(percentile(latencies, 95), 3),
        "latency_ms_p99": round(percentile(latencies, 99), 3),
    }
    print(f"RESULT {json.dumps(result, sort_keys=True)}")

    for message in error_messages:
        print(f"Worker error: {message}", file=sys.stderr)

    target_missed = (
        args.transactions is not None and committed != args.transactions
    )
    if target_missed:
        print(
            f"Expected {args.transactions} committed transactions, got {committed}",
            file=sys.stderr,
        )

    return 1 if errors or target_missed else 0


if __name__ == "__main__":
    raise SystemExit(main())
