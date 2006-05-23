require 'roby/enumerate'

# Base class for graph enumeration. Subclasses should define
#   each_edge { |from, to| ... }
#
# and GraphEnumerator defines #each to enumerate the nodes
#
class GraphEnumerator
    include EnumeratorOperations
    include Enumerable

    attr_reader :root, :enum_with, :args
    def initialize(root, enum_with, args)
        @root = root
        @enum_with = enum_with
        @args = args
    end

    def each
	enum_uniq(:each_edge) { |_, child| child }.
	    each { |_, child| yield(child) unless child == @root }
	self
    end
end

# Breadth-first enumerator
class BFSEnumerator < GraphEnumerator
    def each_edge(&iterator)
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

    def topological
        levels = Hash.new(-1)
        levels[@root] = 0
        max_level = 0

        each do |child, parent|
            parent_level, child_level = levels[parent], levels[child]
            if child_level <= parent_level
                child_level = parent_level + 1
                levels[child] = child_level
            end
            max_level = child_level if max_level < child_level
        end

        sorting = Array.new(max_level + 1) { Array.new }
        levels.each { |node, level| sorting[level] << node }

        sorting
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
    def enum_bfs(enum_with = :each, *args, &iterator)
        enumerator = BFSEnumerator.new(self, enum_with, args) 
        if iterator
            enumerator.each(&iterator)
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
    def enum_leafs(enum_with = :each, *args, &iterator) # :yield: 
	leafs	= Set.new
	enum_bfs(enum_with, *args).each_edge do |parent, child|
	    leafs << child
	    leafs.delete(parent)
	end

	if iterator
	    leafs.each(&iterator)
	else
	    leafs
	end
    end
end

