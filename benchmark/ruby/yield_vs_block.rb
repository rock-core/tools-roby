# frozen_string_literal: true

require "benchmark"

def call_yield(enum)
    enum.each { |v| yield(v) }
end

def call_block(enum, &block)
    enum.each(&block)
end

enum = (1..10_000_000)
cost_of_call = 10_000_000
call_count = 1_000
call_enum  = (1..100)
Benchmark.bm(40) do |x|
    x.report(format("yield - enumerate %<calls>.0e elements", calls: enum.size)) do
        call_yield(enum) { |v| }
    end
    x.report(format("block - enumerate %<calls>.0e elements", calls: enum.size)) do
        call_block(enum) { |v| }
    end
    x.report(format("yield - %<calls>.0e calls", calls: cost_of_call)) do
        cost_of_call.times { call_yield((1..1)) { |v| } }
    end
    x.report(format("block - %<calls>.0e calls", calls: cost_of_call)) do
        cost_of_call.times { call_block((1..1)) { |v| } }
    end
    x.report(format("yield - %<calls>.0e calls and %<elements>.0e elements",
                    calls: call_count, elements: call_enum.size)) do
        call_count.times { call_yield(call_enum) { |v| } }
    end
    x.report(format("block - %<calls>.0e calls and %<elements>.0e elements",
                    calls: call_count, elements: call_enum.size)) do
        call_count.times { call_block(call_enum) { |v| } }
    end
end
