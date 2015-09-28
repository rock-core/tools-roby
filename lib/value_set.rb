require 'value_set/value_set'
require 'utilrb/enumerable/to_s_helper'

class ValueSet
    def <<(obj); insert(obj) ; self end
    alias :| :union
    alias :& :intersection
    alias :- :difference
    include Enumerable

    def substract(other_set)
        difference!(other_set.to_value_set)
    end

    def add(value)
        insert(value)
        self
    end

    def to_s
        elements = EnumerableToString.to_s_helper(self, '{', '}') do |obj|
            obj.to_s
        end
        base = super[0..-2]
        "#{base} #{elements}>"
    end
    alias :inspect :to_s

    def _dump(lvl = -1)
        Marshal.dump(to_a)
    end
    def self._load(str)
        Marshal.load(str).to_value_set
    end

    def eql?(obj)
        self == obj
    end

    def hash
        result = ValueSet.hash
        for obj in self
            result = result ^ obj.hash
        end
        result
    end
end
