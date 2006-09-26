require 'roby/event'
require 'roby/task'

module Roby::Transactions
    # This graph behaves as 
    #
    #    base - negative - negative_vertices + positive
    #
    # It is used to model relations during a transaction. We never modify +base+
    # directly, but the other instead. Then, applying the transaction is merging
    # the modifications back into +base+
    class RelationGraph
	attr_reader :base, :positive, :negative, :negative_vertices
	def initialize(base)
	    @base     = base 
	    # The graph of relations to be added
	    @positive = BGL::Graph.new
	    # The graph of relations to be removed
	    @negative = BGL::Graph.new
	    # The graph of removed vertices
	    @negative_vertices = ValueSet.new
	end

	# true if remove(v) has been called at least once
	def removed_vertex?(v)
	    negative_vertices.include?(v)
	end
	# true if the from => to link has been removed 
	def removed_link?(from, to)
	    negative_vertices.include?(from) || 
		negative_vertices.include?(to) || 
		negative.linked?(from, to)
	end

	def linked?(from, to)
	    (base.linked?(from, to) && !removed_link?(from, to)) ||
		positive.linked?(from, to)
	end

	def link(from, to, info = nil)
	    if removed_link?(from, to)
		positive.link(from, to, info)
	    elsif base.linked?(from, to)
		base.link(from, to, info) # for the check on +info+
	    else
		positive.link(from, to, info)
	    end
	end

	def unlink(from, to)
	    if positive.linked?(from, to)
		positive.unlink(from, to)
	    end

	    if base.linked?(from, to)
		negative.link(from, to, from[to, base])
	    end
	end

	def insert(object)
	    if removed_vertex?(object) || !base.include?(object)
		positive.insert(object)
	    end
	end

	def remove(object)
	    positive.remove(object)
	    negative.remove(object)
	    negative_vertices.insert(object)
	end

	def each_vertex(&iterator)
	    positive.each_vertex(&iterator)
	    base.each_vertex do |v|
		next if positive.include?(v) || removed_vertex?(v)
		yield(v)
	    end
	end
	def each_edge(&iterator)
	    positive.each_edge(&iterator)
	    base.each_edge do |source, target, info|
		next if positive.linked?(source, target) || removed_link?(source, target)
		yield(source, target, info)
	    end
	end

	def each_parent_vertex(object)
	    positive.each_parent_vertex(object, &iterator)
	    base.each_parent_vertex do |v|
		next if removed_link?(v, object) || positive.linked?(v, object)
		yield(v)
	    end
	end

	def each_child_vertex(object)
	    positive.each_child_vertex(object, &iterator)
	    base.each_child_vertex do |v|
		next if removed_link?(object, v) || positive.linked?(object, v)
		yield(v)
	    end
	end

	def include?(vertex)
	    positive.include?(vertex) ||
		(base.include?(vertex) && !removed_vertex?(vertex))
	end
	
	# Apply the modifications registered in this transaction graph into +base+
	def apply
	    negative_vertices.each { |v| base.remove(v) }
	    negative.each_edge do |source, target, _|
		base.unlink(source, target) unless negative_vertices.include?(v)
	    end

	    positive.each_vertex { |v| base.insert(v) }
	    positive.each_edge   { |s, t, i| base.link(s, t, i) }
	end
    end

    def self.copy_structure(to_space, from_space)
	from_space.each_relation do |relation_graph|
	    options = relation_graph.options.dup
	    const_name = options.delete(:const_name)
	    to_space.relation const_name, options
	end

	to_space
    end

    TaskStructure  = copy_structure Roby::RelationSpace(Task), Roby::TaskStructure
    EventStructure = copy_structure Roby::RelationSpace(EventGenerator), Roby::EventStructure
end

