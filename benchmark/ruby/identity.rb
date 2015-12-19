require 'benchmark'

obj = Object.new
lambda_identity = lambda { |v| v }
proc_identity = proc { |v| v }
hash_identity = Hash.new { |h,k| k }
klass = Class.new do
    def self.identity(obj); obj end
end
method_identity = klass.method(:identity)

Benchmark.bm(70) do |bm|
    bm.report('lambda') { 10_000_000.times { lambda_identity.call(obj) } }
    bm.report('hash') { 10_000_000.times { hash_identity[obj] } }
    bm.report('proc') { 10_000_000.times { proc_identity[obj] } }
    bm.report('method') { 10_000_000.times { method_identity[obj] } }
end

