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

	alias :child_object?	:child_vertex?	
	alias :parent_object?	:parent_vertex?	
	alias :related_object?	:related_vertex?
	alias :each_child_object 	:each_child_vertex
	alias :each_parent_object 	:each_parent_vertex
	alias :each_relation	:each_graph

	def enum_relations; @enum_relations ||= enum_for(:each_graph) end
	def enum_parent_objects(type)
	    @enum_parent_objects ||= Hash.new
	    @enum_parent_objects[type] ||= enum_for(:each_parent_object, type)
	end
	def enum_child_objects(type)
	    @enum_child_objects ||= Hash.new
	    @enum_child_objects[type] ||= enum_for(:each_child_object, type)
	end
	def relations; enum_relations.to_a end

	def related_objects(relation = nil, result = nil)
	    result ||= ValueSet.new
	    if relation
		result.merge(parent_objects(relation))
		result.merge(child_objects(relation))
	    else
		each_relation { |rel| related_objects(rel, result) }
	    end
	    result
	end

	# Set of all parent objects in +type+
	def parent_objects(relation)
	    enum_parent_objects(relation).to_value_set
	end
	# Set of all child object in +type+
	def child_objects(relation)
	    enum_child_objects(relation).to_value_set
	end

	# Add a new child object in the +type+ relation. This calls
	# * self.adding_child_object and child.adding_parent_object just before the relation is added
	# * self.added_child_object and child.added_child_object just after
	def add_child_object(child, type, info = nil)
	    check_is_relation(type)
	    if type.linked?(self, child)
		if self[child, type] != info
		    raise ArgumentError, "trying to override edge data"
		end
		return
	    end

	    adding_child_object(child, type, info)
	    type.link(self, child, info)
	    added_child_object(child, type, info)
	end
	# Add a new parent object in the +type+ relation
	# * self.adding_child_object and child.adding_parent_object just before the relation is added
	# * self.added_child_object and child.added_child_object just after
	def add_parent_object(parent, type, info = nil)
	    parent.add_child_object(self, type, info)
	end

	# Hook called before a new child is added
	def adding_child_object(child, type, info)
	    child.adding_parent_object(self, type, info)
	    super if defined? super 
	end
	# Hook called after a new child has been added
	def added_child_object(child, type, info)
	    child.added_parent_object(self, type, info)
	    super if defined? super 
	end
	# Hook called after a new parent has been added
	def added_parent_object(parent, type, info); super if defined? super end
	# Hook called after a new parent is being added
	def adding_parent_object(parent, type, info); super if defined? super end

	# Remove the relation between +self+ and +child+. If +type+
	# is given, remove only a +type+ relation
	def remove_child_object(child, type = nil)
	    check_is_relation(type)
	    apply_selection(type, enum_relations) do |type|
		removing_child_object(child, type)
		type.unlink(self, child)
		removed_child_object(child, type)
	    end
	end
	# Remove relations where self is a parent. If +type+
	# is not nil, remove only the +type+ relations
	def remove_children(type = nil)
	    apply_selection(type, enum_relations) do |type|
		self.each_child_object(type) do |child|
		    remove_child_object(child, type)
		end
	    end
	end

	# Remove relations where +self+ is a child. If +type+
	# is not nil, remove only the +type+ relations
	def remove_parent_object(parent, type = nil)
	    parent.remove_child_object(self, type)
	end
	# Remove all parents of +self+. If +type+ is not nil,
	# remove only the parents in the +type+ relation
	def remove_parents(type = nil)
	    check_is_relation(type)
	    apply_selection(type, enum_relations) do |type|
		type.each_parent_object(self) do |parent|
		    remove_parent_object(type, parent)
		end
	    end
	end

	# Hook called after a parent has been removed
	def removing_parent_object(parent, type); super if defined? super end
	# Hook called after a child has been removed
	def removing_child_object(child, type)
	    child.removing_parent_object(self, type)
	    super if defined? super 
	end

	# Hook called after a parent has been removed
	def removed_parent_object(parent, type); super if defined? super end
	# Hook called after a child has been removed
	def removed_child_object(child, type)
	    child.removed_parent_object(self, type)
	    super if defined? super 
	end

	# Remove all relations that point to or come from +to+
	# If +to+ is nil, it removes all relations related to +self+
	def remove_relations(to = nil, type = nil)
	    check_is_relation(type)
	    if to
		remove_parent_object(to, type)
		remove_child_object(to, type)
	    else
		apply_selection(type, enum_relations) do |type|
		    each_parent_object(type) { |parent| remove_parent_object(parent, type) }
		    each_child_object(type) { |child| remove_child_object(child, type) }
		end
	    end
	end

	def replace_object_by(to)
	    each_relation do |rel|
		each_child_object(rel) do |child|
		    to.add_child_object(child, rel, self[child, rel])
		end
		each_parent_object(rel) do |parent|
		    to.add_parent_object(parent, rel, parent[self, rel])
		end
	    end
	    remove_relations
	end

	def check_is_relation(type)
	    if type && !(RelationGraph === type)
		raise ArgumentError, "#{type} (of class #{type.class}) is not a relation type"
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
	attr_reader   :name
	attr_accessor :parent
	attr_reader   :subsets
	attr_reader   :options

	def initialize(name, options = {})
	    @name = name
	    @options = options
	    @subsets = Set.new
	    if options[:subsets]
		options[:subsets].each(&method(:superset_of))
	    end
	end

	def to_s; name end

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
	def apply_on(klass)
	    klass.include DirectedRelationSupport
	    each_relation do |graph|
		klass.include graph.support
	    end

	    applied << klass 
	end
	attribute(:relations) { Array.new }
	attribute(:applied)   { Array.new }

	def each_relation(&iterator)
	    relations.each(&iterator)
	end

	# Creates a new relation in this RelationSpace module. This defines a relation graph
	# in the RelationSpace, and iteration methods on the vertices. If a block is given,
	# it is class_eval'd in the context of the vertex class.
	#
	# = Options
	# child_name:: define a each_#{child_name} method to iterate on the vertex children. 
	#              Uses the relation name by default (a Child relation would be defined 
	#              a each_child method)
	# parent_name:: define a each_#{parent_name} method to iterate on the vertex parents.
	#              If nil, or if none is given, no method is defined
	# subsets:: a list of subgraphs. See RelationGraph#superset_of
	# noinfo:: if the relation embeds some additional information. If true, the child iterator method
	#          (each_#{child_name}) will yield (child, info) instead of only child
	# graph:: the relation graph class
	def relation(relation_name, options = {}, &block)
	    options = validate_options options, 
			:child_name => relation_name.to_s.underscore,
			:parent_name => nil,
			:subsets => Set.new,
			:noinfo => false,
			:graph => RelationGraph

	    options[:const_name] = relation_name
	    graph = options[:graph].new "#{self.name}::#{relation_name}", options

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
		    self.each_parent_object(@@__r_#{relation_name}__, &iterator)
		end
		EOD
	    end
		
	    if options[:noinfo]
		mod.class_eval <<-EOD
		def each_#{options[:child_name]}(&iterator)
		    each_child_object(@@__r_#{relation_name}__, &iterator)
		end
		EOD
	    else
		mod.class_eval <<-EOD
		def each_#{options[:child_name]}
		    each_child_object(@@__r_#{relation_name}__) { |child| yield(child, self[child, @@__r_#{relation_name}__]) }
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
	    relations << graph
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

    # Requires all Roby relation files (all files in relations/)
    def self.load_all_relations
	Dir.glob("#{File.dirname(__FILE__)}/relations/*.rb").each do |file|
	    require "roby/relations/#{File.basename(file, '.rb')}"
	end
    end
end

