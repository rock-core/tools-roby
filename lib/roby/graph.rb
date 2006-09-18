require 'utilrb/enumerable'

# Base class for graph enumeration. Subclasses should define
#   each_edge { |from, to| ... }
#
# and GraphEnumerator defines #each to enumerate the nodes
#
class GraphEnumerator
    include Enumerable

    attr_reader :root, :enum_with, :args
    def initialize(root, enum_with, args)
        @root = root
        @enum_with = enum_with
        @args = args
    end

    def each
	known = Set.new
	each_edge do |_, child|
	    next if child == @root || known.include?(child)
	    known << child
	    yield(child)
	end
	self
    end
end

# Breadth-first enumerator
class BFSEnumerator < GraphEnumerator
    def each_edge
        queue = [@root]
        seen  = Set.new
        while !queue.empty?
            current = queue.shift

            seen << current
            current.send(@enum_with, *@args) do |node|
                yield [current, node]
		unless seen.include?(node)
		    seen << node
		    queue << node
		end
            end
        end

	self
    end
end

# Depth-first enumeration
class DFSEnumerator < GraphEnumerator
    def each_edge(&iterator)
        enumerate(@root, Set.new, &iterator) 
	self
    end

    def enumerate(object, seen, &iterator)
        object.send(@enum_with, *@args) do |node|
	    unless seen.include?(node)
		seen << node
		enumerate(node, seen, &iterator)
	    end
            yield [object, node]
        end
    end
end

class Object
    # Enumerates an iterator-based graph depth-first
    def enum_dfs(enum_with = :each, *args, &iterator) 
        enumerator = DFSEnumerator.new(self, enum_with, args) 
        if iterator
            enumerator.each(&iterator)
        else
            enumerator
        end
    end

    # Enumerates an iterator-based graph breadth-first
    def enum_bfs(enum_with = :each, *args)
        enumerator = BFSEnumerator.new(self, enum_with, args) 
        if block_given?
            enumerator.each { |o| yield(o) }
        else
            enumerator
        end
    end

    # :call-seq:
    #	enum_leafs(enum_with = :each, *args) { |leaf| ... }	=> leaf set
    #	enum_leafs(enum_with = :each, *args)			=> leaf set
    #	
    # The first form is equivalent to doing
    #   enum_leafs(...).each { |leaf| ... }
    #
    # Enumerate all leafs of an iterator-based graph
    def enum_leafs(enum_with = :each, *args) # :yield: leaf
	leafs	= Set.new
	enum_bfs(enum_with, *args).each_edge do |parent, child|
	    leafs << child
	    leafs.delete(parent)
	end

	if block_given?
	    leafs.each { |l| yield(l) }
	else
	    leafs
	end
    end
end


module BGL
    module Vertex
	def clear
	    each_graph { |g| g.remove(self) }
	end
    end
end

