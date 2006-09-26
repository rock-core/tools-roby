require 'roby/support'
require 'roby/graph'

module Roby
    class NoRelationError < RuntimeError; end

    # Base support for relations. It is mixed-in objects that are
    # part of relation networks (like Task and EventGenerator)
    # It is used by the DirectedRelation module, which is used
    # to define the relation modules (like TaskSupport::Hierarchy)
    module DirectedRelationSupport
	include BGL::Vertex

	private :child_vertex?	
	private :parent_vertex?	
	private :related_vertex?
	private :each_child_vertex
	private :each_parent_vertex

	def child_object?(v, type = nil)
	    apply_selection(type, enum_relations).
		find { |type| type.linked?(self, v) }
	end
	def parent_object?(v, type = nil); v.child_object?(self, type) end
	def related_object?(v); child_object?(v) || parent_object?(v) end
	def each_parent_object(type = nil, &iterator)
	    if type
		type.each_parent_vertex(self, &iterator)
	    else
		enum_all_parents.each(&iterator)
	    end
	end

	def each_child_object(type = nil, &iterator)
	    if type
		type.each_child_vertex(self, &iterator)
	    else
		enum_all_children.each_uniq(&iterator)
	    end
	end
	    
	def enum_relations; @enum_relations ||= enum_for(:each_graph) end
	def each_child_object_aux(&iterator); each_graph { |r| r.each_child_vertex(self, &iterator) } end
	def enum_all_children; @enum_all_children ||= enum_for(:each_child_object_aux) end
	def each_parent_object_aux(&iterator); each_graph { |r| r.each_parent_vertex(self, &iterator) } end
	def enum_all_parents; @enum_all_parents ||= enum_for(:each_parent_object_aux) end
	def relations; enum_relations.to_a end

	# Add a new relation
	def add_child_object(to, type, info = nil)
	    type.link(self, to, info)
	    added_child_object(to, type, info)
	end
	# Hook called after a new child has been added
	def added_child_object(to, type, info)
	    super if defined? super
	end

	# Remove relations where self is a parent
	def remove_child_object(to, type = nil)
	    apply_selection(type, enum_relations) do |type|
		type.unlink(self, to)
		removed_child_object(to, type)
	    end
	end
	def remove_children(type = nil)
	    apply_selection(type, enum_relations) do |type|
		type.each_child_vertex(self) do |to|
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
	    apply_selection(type, enum_relations) do |type|
		type.unlink(to, self)
		removed_parent_object(to, type)
	    end
	end
	def remove_parents(type = nil)
	    apply_selection(type, enum_relations) do |type|
		type.each_parent_vertex(self) do |to|
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
	    clear_links(type)
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
	attr_reader   :name
	attr_accessor :parent
	attr_reader   :subsets

	def initialize(name, subsets)
	    @name = name
	    @subsets = Set.new
	    subsets.each { |r| superset_of(r) }
	end

	def link(from, to, info = nil)
	    if linked?(from, to)
		if from[to, self] != info
		    raise ArgumentError, "edge already exists and info differs"
		end
	    else
		parent.link(from, to, info) if parent
		super
	    end
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

    class RelationSpace < Module
	def apply_on(klass); applied << klass end
	attribute(:applied) { Array.new }

	def relation(relation_name, options = {}, &block)
	    options = validate_options options, 
			:child_name => relation_name.to_s.underscore,
			:parent_name => nil,
			:subsets => Set.new,
			:noinfo => false

	    graph = RelationGraph.new "#{self.name}::#{relation_name}", options[:subsets]

	    mod = Module.new do
		singleton_class.class_eval do
		    define_method("__r_#{relation_name}__") { graph }
		end
		class_eval "@@__r_#{relation_name}__ = __r_#{relation_name}__"
		class_eval(&block) if block_given?
	    end

	    if parent_enumerator = options[:parent_name]
		mod.class_eval <<-EOD
		def each_#{parent_enumerator}(&iterator)
		    @@__r_#{relation_name}__.each_parent_vertex(self, &iterator)
		end
		EOD
	    end
		
	    if options[:noinfo]
		mod.class_eval <<-EOD
		def each_#{options[:child_name]}(&iterator)
		    @@__r_#{relation_name}__.each_child_vertex(self, &iterator)
		end
		EOD
	    else
		mod.class_eval <<-EOD
		def each_#{options[:child_name]}
		    @@__r_#{relation_name}__.each_child_vertex(self) { |child| yield(child, self[child, @@__r_#{relation_name}__]) }
		end
		EOD
	    end
	    mod.class_eval <<-EOD
	    def add_#{options[:child_name]}(to, info = nil)
		add_child_object(to, @@__r_#{relation_name}__, info)
		self
	    end
	    def remove_#{options[:child_name]}(to)
		remove_child_object(to, @@__r_#{relation_name}__)
		self
	    end
	    EOD

	    graph.support = mod
	    const_set(relation_name, graph)
	    applied.each { |klass| klass.include mod }

	    graph
	end
    end

    def self.RelationSpace(klass, &block)
	klass.include DirectedRelationSupport
	relation_space = RelationSpace.new do
	    apply_on klass
	end
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

    # Requires all Roby relation files (all files in relations/)
    def self.load_all_relations
	Dir.glob("#{File.dirname(__FILE__)}/relations/*.rb").each do |file|
	    require "roby/relations/#{File.basename(file, '.rb')}"
	end
    end
end

