defmodule BreakerInternalsBench do
  use Benchfella

  before_each_bench _ do
    Breaker.start_link([url: "http://localhost:8080/"])
  end

  after_each_bench pid do
    Process.exit(pid, :normal)
  end

  bench "ask if open", [pid: bench_context] do
    Breaker.open?(pid)
    :ok
  end

  bench "manually trip circuit", [pid: bench_context] do
    Breaker.trip(pid)
  end

  bench "manually reset circuit", [pid: bench_context] do
    Breaker.reset(pid)
  end

  bench "manually recalculate the circuit's status", [pid: bench_context] do
    GenServer.cast(pid, :recalculate)
  end

  bench "count a hit", [pid: bench_context] do
    Breaker.count(pid, %HTTPoison.Response{status_code: 200})
  end

  bench "count a miss", [pid: bench_context] do
    Breaker.count(pid, %HTTPoison.Response{status_code: 500})
  end

  bench "count a timeout", [pid: bench_context] do
    Breaker.count(pid, %HTTPoison.Error{})
  end

  bench "roll the health window", [pid: bench_context] do
    Breaker.roll(pid)
  end

  bench "get options", [pid: bench_context] do
    GenServer.call(pid, :options)
  end
end
