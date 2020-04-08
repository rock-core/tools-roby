# frozen_string_literal: true

require "benchmark"
require "set"

class Set
    def intersect_with_merge(other)
        result = Set.new
        @hash.merge(other.instance_variable_get(:@hash)) do |k, _|
            result << k
        end
        result
    end
end

Benchmark.bm(40) do |x|
    [1, 10, 100, 1000].each do |count|
        sets = []
        10_000.times do
            elements = (0..count * 2).to_a
            left = Set.new
            right = Set.new
            count.times do
                left << (elements[rand(count * 2)])
                right << (elements[rand(count * 2)])
            end
            sets << [left, right]
        end
        x.report("#{count}: Set#intersect") do
            sets.each do |left, right|
                left & right
            end
        end
        x.report("#{count}: Set#intersect_with_merge") do
            sets.each do |left, right|
                left.intersect_with_merge(right)
            end
        end
    end
end
