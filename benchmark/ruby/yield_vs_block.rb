require 'benchmark'

def call_yield(enum)
    enum.each { |v| yield(v) }
end

def call_block(enum, &b)
    enum.each(&b)
end

enum       = (1..10_000_000)
cost_of_call = 10_000_000
call_count = 1_000
call_enum  = (1..100)
Benchmark.bm(40) do |x|
    x.report("yield - enumerate %.0e elements" % [enum.size]) do
        call_yield(enum) { |v| }
    end
    x.report("block - enumerate %.0e elements" % [enum.size]) do
        call_block(enum) { |v| }
    end
    x.report("yield - %.0e calls" % [cost_of_call]) do
        cost_of_call.times { call_yield((1..1)) { |v| } }
    end
    x.report("block - %.0e calls" % [cost_of_call]) do
        cost_of_call.times { call_block((1..1)) { |v| } }
    end
    x.report("yield - %.0e calls and %.0e elements" % [call_count, call_enum.size]) do
        call_count.times { call_yield(call_enum) { |v| } }
    end
    x.report("block - %.0e calls and %.0e elements" % [call_count, call_enum.size]) do
        call_count.times { call_block(call_enum) { |v| } }
    end
end

