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
	alias :clear_relations  :clear_vertex

	def enum_relations; @enum_relations ||= enum_for(:each_graph) end
	def enum_parent_objects(type)
	    @enum_parent_objects ||= Hash.new
	    @enum_parent_objects[type] ||= enum_for(:each_parent_object, type)
	end
	def enum_child_objects(type)
	    @enum_child_objects ||= Hash.new
	    @enum_child_objects[type] ||= enum_for(:each_child_object, type)
	end

	# The set of relations the object is part of
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

	# Set of all parent objects in +relation+
	def parent_objects(relation)
	    enum_parent_objects(relation).to_value_set
	end
	# Set of all child object in +relation+
	def child_objects(relation)
	    enum_child_objects(relation).to_value_set
	end

	# Add a new child object in the +type+ relation. This calls
	# * self.adding_child_object and child.adding_parent_object just before
	#   the relation is added
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
	    type.add_relation(self, child, info)
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
		type.remove_relation(self, child)
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

	# Replaces +self+ by +to+ in all graphs +self+ is part of. Unlike BGL::Vertex#replace_by,
	# this calls the various add/remove hooks defined by DirectedRelationSupport
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

	# Raises if +type+ does not look like a relation
	def check_is_relation(type) # :nodoc:
	    if type && !(RelationGraph === type)
		raise ArgumentError, "#{type} (of class #{type.class}) is not a relation type"
	    end
	end

	def apply_selection(object, enumerator) # :nodoc:
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
    
    # This class manages the graph defined by an object relation in Roby.
    # Relation graphs are managed in hierarchies (for instance, Precedence is a
    # superset of CausalLink, and CausalLink a superset of both Forwarding and
    # Signal). In this hierarchy, at each level, an edge cannot be present in
    # more than one graph. Nonetheless, it is possible for a parent relation to
    # have an edge which is present in none of its children.
    class RelationGraph < BGL::Graph
	# The relation name
	attr_reader   :name
	# The relation parent if any
	attr_accessor :parent
	# The set of graphs
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

	# True if the relation can be seen by remote plan databases
	def distribute?; options[:distribute] end

	# Add a new relation between +from+ and +to+. The relation is
	# added on all parent relation graphs as well. 	
	def add_relation(from, to, info = nil)
	    if !linked?(from, to) && parent
		from.add_child_object(to, parent, info)
	    end

	    link(from, to, info)
	end

	# Reimplemented from BGL::Graph. Unlike this implementation, it is
	# possible to add an already existing edge if the +info+ parameter
	# matches.
	def link(from, to, info)
	    if linked?(from, to)
		if info != from[to, self]
		    raise ArgumentError, "trying to change edge information"
		end
		return
	    end
	    super
	end

	# Remove the relation between +from+ and +to+, in this graph and in its
	# parent graphs as well
	def remove_relation(from, to)
	    if parent
		from.remove_child_object(to, parent)
	    end
	    unlink(from, to)
	end
	
	# Returns true if +relation+ is included in this relation (i.e. it is either
	# the same relation or one of its subsets)
	def subset?(relation)
	    self.eql?(relation) || subsets.any? { |subrel| subrel.subset?(relation) }
	end

	def linked_in_hierarchy?(source, target) # :nodoc:
	    linked?(source, target) || (parent.linked?(source, target) if parent)
	end

	# Declare that +relation+ is a superset of this relation
	def superset_of(relation)
	    relation.each_edge do |source, target, info|
		if linked_in_hierarchy?(source, target)
		    raise ArgumentError, "relation and self already share an edge"
		end
	    end

	    relation.parent = self
	    subsets << relation

	    # Copy the relations of the child into this graph
	    relation.each_edge do |source, target, info|
		source.add_child_object(target, self, info)
	    end
	end
	
	# The Ruby module that gets included in graph objects
	attr_accessor :support
    end

    # A relation space is a module which handles a list of relations and
    # applies them to a set of classes. In this context, a relation is both a
    # Ruby module which gets included in the classes this space is applied on,
    # and a RelationGraph object which holds the object graphs.
    #
    # See the files in roby/relations to see definitions of new relations
    class RelationSpace < Module
	# This relation should apply on +klass+
	def apply_on(klass)
	    klass.include DirectedRelationSupport
	    each_relation do |graph|
		klass.include graph.support
	    end

	    applied << klass 
	end
	# The set of relations included in this relation space
	attribute(:relations) { Array.new }
	# The set of klasses on which the relations have been applied
	attribute(:applied)   { Array.new }

	# Yields the relations that are included in this space
	def each_relation(&iterator)
	    relations.each(&iterator)
	end

	# Creates a new relation in this relation space. This defines a
	# relation graph in the RelationSpace, and iteration methods on the
	# vertices. If a block is given, it is class_eval'd in the context of
	# the relation module, which is included in the applied classes.
	#
	# = Options
	# child_name:: define a each_#{child_name} method to iterate on the
	#	       vertex children.  Uses the relation name by default (a Child relation
	# 	       would be define a each_child method)
	# parent_name:: define a each_#{parent_name} method to iterate on the vertex parents.
	#               If nil, or if none is given, no method is defined
	# subsets:: a list of subgraphs. See RelationGraph#superset_of [empty set]
	# noinfo:: if the relation embeds some additional information. If true, the child iterator method
	#          (each_#{child_name}) will yield (child, info) instead of only child [false]
	# graph:: the relation graph class
	# distribute:: if true, the relation can be seen by remote peers [true]
	def relation(relation_name, options = {}, &block)
	    options = validate_options options, 
			:child_name => relation_name.to_s.underscore,
			:parent_name => nil,
			:subsets => Set.new,
			:noinfo => false,
			:graph => RelationGraph,
			:distribute => true

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

    # Creates a new relation space which applies on +klass+. If a block is
    # given, it is eval'd in the context of the new relation space instance
    def self.RelationSpace(klass, &block)
	klass.include DirectedRelationSupport
	relation_space = RelationSpace.new do
	    apply_on klass
	end
	relation_space.class_eval(&block) if block_given?
	relation_space
    end

    # Requires all Roby relation files (all files in roby/relations/)
    def self.load_all_relations
	Dir.glob("#{File.dirname(__FILE__)}/relations/*.rb").each do |file|
	    require "roby/relations/#{File.basename(file, '.rb')}"
	end
    end
end

