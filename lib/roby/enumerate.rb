require 'enumerator'
require 'set'

module EnumeratorOperations
    def +(other_enumerator)
	SequenceEnumerator.new << self << other_enumerator
    end
end

class NullEnumerator
    include EnumeratorOperations
    def each; self end
end

class SequenceEnumerator
    extend Forwardable
    def initialize; @sequence = Array.new end

    def <<(object); @sequence << object; self end

    def each(&iterator)
	@sequence.each { |enum| enum.each(&iterator) }
	self
    end
    include EnumeratorOperations
    include Enumerable
end

class Enumerable::Enumerator
    include EnumeratorOperations
end

class UniqEnumerator
    include EnumeratorOperations
    def initialize(root, enum_with, args, key = nil)
	@root, @enum_with, @args = root, enum_with, args

	@key = if key.respond_to?(:call)
		   key
	       elsif key
		   lambda { |v| v.send(key) }
	       else
		   lambda { |v| v.hash }
	       end

	@seen = Set.new
    end

    def each
	@seen.clear
	@root.send(@enum_with, *@args) do |v|
	    k = @key[v]
	    if !@seen.include?(k)
		@seen << k
		yield(v)
	    end
	end

	self
    end

    include Enumerable
end

class Object
    # Enumerate removing the duplicate entries
    def enum_uniq(enum_with = :each, *args, &filter)
	UniqEnumerator.new(self, enum_with, args, filter)
    end
end

