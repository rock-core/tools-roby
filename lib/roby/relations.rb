require 'roby/support'
require 'roby/graph'

module Roby
    class CycleFoundError < RuntimeError; end
    # Base support for relations. It is mixed-in objects that are part of
    # relation networks (like Task and EventGenerator)
    module DirectedRelationSupport
	include BGL::Vertex

	alias :child_object?	    :child_vertex?	
	alias :parent_object?	    :parent_vertex?	
	alias :related_object?	    :related_vertex?
	alias :each_child_object    :each_child_vertex
	alias :each_parent_object   :each_parent_vertex
	alias :each_relation	    :each_graph
	alias :clear_relations	    :clear_vertex

	# Cache an enumerator object for the relations this object is part of
	def enum_relations # :nodoc:
	    @enum_relations ||= enum_for(:each_graph) 
	end
	# Cache an Enumerator object for parents in the +type+ relation
	def enum_parent_objects(type) # :nodoc:
	    @enum_parent_objects ||= Hash.new
	    @enum_parent_objects[type] ||= enum_for(:each_parent_object, type)
	end
	# Cache an Enumerator object for children in the +type+ relation
	def enum_child_objects(type) # :nodoc:
	    @enum_child_objects ||= Hash.new
	    @enum_child_objects[type] ||= enum_for(:each_child_object, type)
	end

	# The array of relations this object is part of
	def relations; enum_relations.to_a end

	# Computes and returns the set of objects related with this one (parent
	# or child). If +relation+ is given, enumerate only for this relation,
	# otherwise enumerate for all relations.  If +result+ is given, it is a
	# ValueSet in which the related objects are added
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

	# Add a new child object in the +relation+ relation. This calls
	# * #adding_child_object on +self+ and #adding_parent_object on +child+
	#   just before the relation is added
	# * #added_child_object on +self+ and #added_parent_object on +child+
	#   just after
	def add_child_object(child, relation, info = nil)
	    check_is_relation(relation)
	    if relation.linked?(self, child)
		if self[child, relation] != info
		    raise ArgumentError, "trying to override edge data. Was #{self[child, relation]}, new info is #{info}"
		end
		return
	    end

	    adding_child_object(child, relation, info)
	    relation.add_relation(self, child, info)
	    added_child_object(child, relation, info)
	end

	# Add a new parent object in the +relation+ relation
	# * #adding_child_object on +parent+ and #adding_parent_object on
	#   +self+ just before the relation is added
	# * #added_child_object on +parent+ and #added_child_object on +self+
	#   just after
	def add_parent_object(parent, relation, info = nil)
	    parent.add_child_object(self, relation, info)
	end

	# Hook called before a new child is added in the +relation+ relation
	def adding_child_object(child, relation, info)
	    child.adding_parent_object(self, relation, info)
	    super if defined? super 
	end
	# Hook called after a new child has been added in the +relation+ relation
	def added_child_object(child, relation, info)
	    child.added_parent_object(self, relation, info)
	    super if defined? super 
	end

	# Hook called after a new parent has been added in the +relation+ relation
	def added_parent_object(parent, relation, info); super if defined? super end
	# Hook called after a new parent is being added in the +relation+ relation
	def adding_parent_object(parent, relation, info); super if defined? super end

	# Remove the relation between +self+ and +child+. If +relation+ is
	# given, remove only a relations in this relation kind.
	def remove_child_object(child, relation = nil)
	    check_is_relation(relation)
	    apply_selection(relation, (relation || enum_relations)) do |relation|
		removing_child_object(child, relation)
		relation.remove_relation(self, child)
		removed_child_object(child, relation)
	    end
	end

	# Remove relations where self is a parent. If +relation+ is given,
	# remove only the relations in this relation graph.
	def remove_children(relation = nil)
	    apply_selection(relation, (relation || enum_relations)) do |relation|
		self.each_child_object(relation) do |child|
		    remove_child_object(child, relation)
		end
	    end
	end

	# Remove relations where +self+ is a child. If +relation+ is given,
	# remove only the relations in this relation graph
	def remove_parent_object(parent, relation = nil)
	    parent.remove_child_object(self, relation)
	end
	# Remove all parents of +self+. If +relation+ is given, remove only the
	# parents in this relation graph
	def remove_parents(relation = nil)
	    check_is_relation(relation)
	    apply_selection(relation, (relation || enum_relations)) do |relation|
		relation.each_parent_object(self) do |parent|
		    remove_parent_object(relation, parent)
		end
	    end
	end

	# Hook called after a parent has been removed
	def removing_parent_object(parent, relation); super if defined? super end
	# Hook called after a child has been removed
	def removing_child_object(child, relation)
	    child.removing_parent_object(self, relation)
	    super if defined? super 
	end

	# Hook called after a parent has been removed
	def removed_parent_object(parent, relation); super if defined? super end
	# Hook called after a child has been removed
	def removed_child_object(child, relation)
	    child.removed_parent_object(self, relation)
	    super if defined? super 
	end

	# Remove all relations that point to or come from +to+ If +to+ is nil,
	# it removes all relations of +self+
	def remove_relations(to = nil, relation = nil)
	    check_is_relation(relation)
	    if to
		remove_parent_object(to, relation)
		remove_child_object(to, relation)
	    else
		apply_selection(relation, (relation || enum_relations)) do |relation|
		    each_parent_object(relation) { |parent| remove_parent_object(parent, relation) }
		    each_child_object(relation) { |child| remove_child_object(child, relation) }
		end
	    end
	end

	# Raises if +type+ does not look like a relation
	def check_is_relation(type) # :nodoc:
	    if type && !(RelationGraph === type)
		raise ArgumentError, "#{type} (of class #{type.class}) is not a relation type"
	    end
	end

	# If +object+ is given, yields object or returns +object+ (if a block
	# is given or not).  If +object+ is nil, either yields the elements of
	# +enumerator+ or returns enumerator.
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
	# The graph options as given to RelationSpace#relation
	attr_reader   :options

	# Creates a new relation graph named +name+ with options +options+. The following options are
	# recognized:
	# +dag+:: if the graph is a DAG. If true, add_relation will check that
	#   no cycle is created
	# +subsets+:: a set of RelationGraph objects that are children of this
	#   one
	# +distributed+:: if this relation graph should be seen by remote hosts
	def initialize(name, options = {})
	    @name = name
	    @options = options
	    @subsets = Set.new

	    if options.has_key?(:dag)
		@dag = options[:dag]
	    else
		@dag = true
	    end

	    if options[:subsets]
		options[:subsets].each(&method(:superset_of))
	    end
	end

	# True if this relation graph is a DAG
	def dag?; @dag end
	def to_s; name end

	# True if this relation does not have a parent
	def root_relation?; !parent end

	# True if the relation can be seen by remote plan databases
	def distribute?; options[:distribute] end

	# Add a new relation between +from+ and +to+. The relation is
	# added on all parent relation graphs as well. 	
	#
	# If #dag? is true, it checks that the new relation does not create a
	# cycle
	def add_relation(from, to, info = nil)
	    if !linked?(from, to) 
		if parent
		    from.add_child_object(to, parent, info)
		elsif dag? && to.generated_subgraph(self).include?(from)
		    # No need to test that we won't create a cycle in child
		    # relations, since the parent relation graphs are the union
		    # of all their children
		    raise CycleFoundError, "cannot add a #{from} -> #{to} relation since it would create a cycle"
		end
	    end

	    # If the link already exists, call #link anyway. It will check that
	    # the edge info remains the same
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
	
	# Returns true if +relation+ is included in this relation (i.e. it is
	# either the same relation or one of its children)
	def subset?(relation)
	    self.eql?(relation) || subsets.any? { |subrel| subrel.subset?(relation) }
	end

	# Returns +true+ if there is an edge +source+ -> +target+ in this graph
	# or in one of its parents
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
	# child_name:: 
	#   define a <tt>each_#{child_name}</tt> method to iterate
	#   on the vertex children. Uses the relation name by default (a Child
	#   relation would define a <tt>each_child</tt> method)
	# parent_name:: 
	#   define a <tt>each_#{parent_name}</tt> method to iterate
	#   on the vertex parents.  If none is given, no method is defined
	# subsets:: a list of subgraphs. See RelationGraph#superset_of
	# noinfo:: 
	#   if the relation embeds some additional information. If true,
	#   the child iterator method (<tt>each_#{child_name}</tt>) will yield (child,
	#   info) instead of only child [false]
	# graph:: the relation graph class
	# distribute:: if true, the relation can be seen by remote peers [true]
	# single_child:: 
	#   if the relations accepts only one child per vertex
	#   [false]. If this option is set, defines a <tt>#{child_name}</tt>
	#   method which returns the only child or nil
	def relation(relation_name, options = {}, &block)
	    options = validate_options options, 
			:child_name => relation_name.to_s.underscore,
			:const_name => relation_name,
			:parent_name => nil,
			:subsets => Set.new,
			:noinfo => false,
			:graph => RelationGraph,
			:distribute => true,
			:single_child => false

	    # Check if this relation is already defined. If it is the case, reuse it.
	    # This is needed mostly by the reloading code
	    begin 
		graph = const_get(options[:const_name])
		mod   = graph.support

	    rescue NameError
		graph = options[:graph].new "#{self.name}::#{options[:const_name]}", options
		mod = Module.new do
		    singleton_class.class_eval do
			define_method("__r_#{relation_name}__") { graph }
		    end
		    class_eval "@@__r_#{relation_name}__ = __r_#{relation_name}__"
		end
		const_set(options[:const_name], graph)
		relations << graph
	    end

	    mod.class_eval(&block) if block_given?

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

	    if options[:single_child]
		mod.class_eval <<-EOD
		def #{options[:child_name]}
		    each_child_object(@@__r_#{relation_name}__) do |child_task|
			return child_task
		    end
		    nil
		end
		EOD
	    end

	    graph.support = mod
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

