require 'roby/support'
require 'roby/bgl'

module Roby
    class NoRelationError < RuntimeError; end

    # Base support for relations. It is mixed-in objects that are
    # part of relation networks (like Task and EventGenerator)
    # It is used by the DirectedRelation module, which is used
    # to define the relation modules (like TaskSupport::Hierarchy)
    module DirectedRelationSupport
	include BGL::Vertex

	alias :child_object?	:child_vertex?	
	alias :parent_object?	:parent_vertex?	
	alias :related_object?	:related_vertex?
	alias :each_child_object 	:each_child_vertex
	alias :each_parent_object 	:each_parent_vertex

	def enum_relations; @enum_relations ||= enum_for(:each_graph) end
	def relations; enum_relations.to_a end

	# Add a new relation
	def add_child_object(to, type, info = nil)
	    check_is_relation(type)
	    type.link(self, to, info)
	    added_child_object(to, type, info)
	end
	# Hook called after a new child has been added
	def added_child_object(to, type, info)
	    super if defined? super
	end

	# Remove relations where self is a parent
	def remove_child_object(to, type = nil)
	    check_is_relation(type)
	    apply_selection(type, enum_relations) do |type|
		type.unlink(self, to)
		removed_child_object(to, type)
	    end
	end
	def remove_children(type = nil)
	    apply_selection(type, enum_relations) do |type|
		self.each_child_object(type) do |to|
		    remove_child_object(to, type)
		end
	    end
	end
	# Hook called after a child has been removed
	def removed_child_object(to, type)
	    super if defined? super
	end

	# Remove relations where self is a child
	def remove_parent_object(to, type = nil)
	    check_is_relation(type)
	    apply_selection(type, enum_relations) do |type|
		type.unlink(to, self)
		removed_parent_object(to, type)
	    end
	end
	def remove_parents(type = nil)
	    check_is_relation(type)
	    apply_selection(type, enum_relations) do |type|
		type.each_parent_object(self) do |to|
		    remove_parent_object(type, to)
		end
	    end
	end
	# Hook called after a parent has been removed
	def removed_parent_object(to, type)
	    super if defined? super
	end

	# Remove all relations that point to or come from +to+
	# If +to+ is nil, it removes all relations related to +self+
	def remove_relations(to = nil, type = nil)
	    check_is_relation(type)
	    clear_links(type)
	end

	def check_is_relation(type)
	    if type && !(RelationGraph === type)
		raise ArgumentError, "#{type} is not a relation type"
	    end
	end

	def apply_selection(object, enumerator)
	    if block_given?
		if object; yield(object)
		else enumerator.each { |o| yield(o) }
		end
	    else
		if object; [object]
		else; enumerator
		end
	    end
	end
	private :apply_selection
    end

    class RelationGraph < BGL::Graph
	attr_reader :name
	attr_accessor :parent
	attr_reader :subsets

	def initialize(name, subsets)
	    @name = name
	    @subsets = Set.new
	    subsets.each { |r| superset_of(r) }
	end

	def link(from, to, info = nil)
	    parent.link(from, to, info) if parent
	    super
	end
	def unlink(from, to)
	    parent.unlink(from, to) if parent
	    super
	end
	
	# Returns true if +relation+ is included in this relation (i.e. it is either
	# the same relation or one of its subsets)
	def subset?(relation)
	    self.eql?(relation) || subsets.any? { |subrel| subrel.subset?(relation) }
	end

	def linked_in_hierarchy?(source, target)
	    linked?(source, target) || (parent.linked?(source, target) if parent)
	end
	def superset_of(relation)
	    relation.each_edge do |source, target, info|
		if linked_in_hierarchy?(source, target)
		    raise ArgumentError, "relation and self already share an edge"
		end
	    end

	    relation.parent = self
	    subsets << relation
	    relation.each_edge do |source, target, info|
		link(source, target, info)
	    end
	end
	
	# The support module that gets included in graph objects
	attr_accessor :support
    end

    def self.RelationSpace(klass, &block)
	relation_space = Module.new
	relation_space.singleton_class.class_eval do
	    define_method(:new_relation_type) do |relation_name, options, block|
		options = validate_options options, 
			    :const_name => relation_name.to_s.camelize.pluralize, 
			    :subsets => Set.new,
			    :parent_enumerator => nil,
			    :noinfo => false

		graph = RelationGraph.new relation_name, options[:subsets]

		mod = Module.new
		mod.class_eval(&block) if block

		if parent_enumerator = options[:parent_enumerator]
		    mod.class_eval <<-EOD
		    def each_#{parent_enumerator}(&iterator)
			self.each_parent_object(@@__r_#{relation_name}__, &iterator)
		    end
		    EOD
		end
		    
		mod.singleton_class.class_eval { define_method("__r_#{relation_name}__") { graph } }
		if options[:noinfo]
		    mod.class_eval <<-EOD
		    def each_#{relation_name}(&iterator)
			each_child_object(@@__r_#{relation_name}__, &iterator)
		    end
		    EOD
		else
		    mod.class_eval <<-EOD
		    def each_#{relation_name}
			each_child_object(@@__r_#{relation_name}__) { |child| yield(child, self[child, @@__r_#{relation_name}__]) }
		    end
		    EOD
		end
		mod.class_eval <<-EOD
		@@__r_#{relation_name}__ = __r_#{relation_name}__
		def add_#{relation_name}(to, info = nil)
		    add_child_object(to, @@__r_#{relation_name}__, info)
		    self
		end
		def remove_#{relation_name}(to)
		    remove_child_object(to, @@__r_#{relation_name}__)
		    self
		end
		EOD

		graph.support = mod
		relation_space.const_set(options[:const_name], graph)
		klass.include mod

		graph
	    end
	end
	relation_space.singleton_class.class_eval "def relation(mod, options = {}, &block); new_relation_type(mod, options, block) end"
	relation_space.class_eval(&block) if block_given?
	relation_space
    end

    class Task
	include DirectedRelationSupport
    end
    class EventGenerator
	include DirectedRelationSupport
    end
    
    TaskStructure   = RelationSpace(Task)
    EventStructure  = RelationSpace(EventGenerator)
end

