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

	cached_enum("graph", "relations", false)
	cached_enum("parent_object", "parent_objects", true)
	cached_enum("child_object", "child_objects", true)

	# The array of relations this object is part of
	def relations; enum_relations.to_a end

	# Computes and returns the set of objects related with this one (parent
	# or child). If +relation+ is given, enumerate only for this relation,
	# otherwise enumerate for all relations.  If +result+ is given, it is a
	# ValueSet in which the related objects are added
	def related_objects(relation = nil, result = nil)
	    result ||= ValueSet.new
	    if relation
		result.merge(parent_objects(relation).to_value_set)
		result.merge(child_objects(relation).to_value_set)
	    else
		each_relation { |rel| related_objects(rel, result) }
	    end
	    result
	end

	# Set of all parent objects in +relation+
	alias :parent_objects :enum_parent_objects
	# Set of all child object in +relation+
	alias :child_objects :enum_child_objects

	# Add a new child object in the +relation+ relation. This calls
	# * #adding_child_object on +self+ and #adding_parent_object on +child+
	#   just before the relation is added
	# * #added_child_object on +self+ and #added_parent_object on +child+
	#   just after
	def add_child_object(child, relation, info = nil)
	    check_is_relation(relation)
	    relation.add_relation(self, child, info)
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
	# def adding_child_object(child, relation, info)
	#     child.adding_parent_object(self, relations, info)
	#     super if defined? super
	# end
	# Hook called after a new child has been added in the +relation+ relation
	# def added_child_object(child, relations, info)
	#     child.added_parent_object(self, relation, info)
	#     super if defined? super
	# end

	# Hook called after a new parent has been added in the +relation+ relation
	#def added_parent_object(parent, relation, info); super if defined? super end
	## Hook called after a new parent is being added in the +relation+ relation
	#def adding_parent_object(parent, relation, info); super if defined? super end

	# Remove the relation between +self+ and +child+. If +relation+ is
	# given, remove only a relations in this relation kind.
	def remove_child_object(child, relation = nil)
	    check_is_relation(relation)
	    apply_selection(relation, (relation || enum_relations)) do |relation|
		relation.remove_relation(self, child)
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
	# def removing_parent_object(parent, relation); super if defined? super end
	# Hook called after a child has been removed
	# def removing_child_object(child, relation)
	#     child.removing_parent_object(self, relation)
	#     super if defined? super
	# end

	# Hook called after a parent has been removed
	# def removed_parent_object(parent, relation); super if defined? super end
	# Hook called after a child has been removed
	# def removed_child_object(child, relation)
	#     child.removed_parent_object(self, relation)
	#     super if defined? super
	# end

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
	    @subsets = ValueSet.new
	    @distribute = options[:distribute]
	    @dag = options[:dag]
	    @weak = options[:weak]

	    if options[:subsets]
		options[:subsets].each(&method(:superset_of))
	    end
	end

	# True if this relation graph is a DAG
	attr_predicate :dag
	# True if this relation should be seen by remote peers
	attr_predicate :distribute
	# If this relation is weak. Weak relations can be removed without major
	# consequences. This is mainly used during plan garbage collection
	attr_predicate :weak

	def to_s; name end

	# True if this relation does not have a parent
	def root_relation?; !parent end

	# Add a new relation between +from+ and +to+. The relation is
	# added on all parent relation graphs as well.
	#
	# If #dag? is true, it checks that the new relation does not create a
	# cycle
	def add_relation(from, to, info = nil)
	    # Get the toplevel DAG in our relation hierarchy. We only test for the
	    # DAG property on this one, as it is the union of all its children
	    top_dag = nil
	    new_relations = []
	    rel     = self
	    while rel
		top_dag = rel if rel.dag?
		new_relations << rel
		rel = rel.parent
	    end
	    if top_dag && !top_dag.linked?(from, to) && top_dag.reachable?(to, from)
		raise CycleFoundError, "cannot add a #{from} -> #{to} relation since it would create a cycle"
	    end

	    # Now compute the set of relations in which we really have to add a
	    # new relation
	    top_rel = new_relations.last
	    if top_rel.linked?(from, to)
		if !(old_info = from[to, top_rel]).nil?
		    if old_info != info
			raise ArgumentError, "trying to change edge information"
		    end
		end

		changed_info = [new_relations.pop]

		while !new_relations.empty?
		    if new_relations.last.linked?(from, to)
			changed_info << new_relations.pop
		    else
			break
		    end
		end

		for rel in changed_info
		    from[to, rel] = info
		end
	    end

	    unless new_relations.empty?
		if from.respond_to?(:adding_child_object)
		    from.adding_child_object(to, new_relations, info)
		end
		if to.respond_to?(:adding_parent_object)
		    to.adding_parent_object(from, new_relations, info)
		end

		for rel in new_relations
		    rel.__bgl_link(from, to, info)
		end

		if from.respond_to?(:added_child_object)
		    from.added_child_object(to, new_relations, info)
		end
		if to.respond_to?(:added_parent_object)
		    to.added_parent_object(from, new_relations, info)
		end
	    end
	end

	alias :__bgl_link :link
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
	    rel = self
	    relations = []
	    while rel
		relations << rel
		rel = rel.parent
	    end

	    if from.respond_to?(:removing_child_object)
		from.removing_child_object(to, relations)
	    end
	    if to.respond_to?(:removing_parent_object)
		to.removing_parent_object(from, relations)
	    end

	    for rel in relations
		rel.unlink(from, to)
	    end

	    if from.respond_to?(:removed_child_object)
		from.removed_child_object(to, relations)
	    end
	    if to.respond_to?(:removed_parent_object)
		to.removed_parent_object(from, relations)
	    end
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
	# The set of relations included in this relation space
	attr_reader :relations
	# The set of klasses on which the relations have been applied
	attr_reader :applied

	def initialize
	    @relations = Array.new
	    @applied   = Array.new
	    super
	end

	# This relation should apply on +klass+
	def apply_on(klass)
	    klass.include DirectedRelationSupport
	    each_relation do |graph|
		klass.include graph.support
	    end

	    applied << klass
	end
	# Yields the relations that are included in this space
	def each_relation
	    for rel in relations
		yield(rel)
	    end
	end
	def each_root_relation
	    for rel in relations
		yield(rel) unless rel.parent
	    end
	end

	# Returns the set of objects that are reachable from +obj+ through any
	# of the relations. Note that +b+ will be included in the result if
	# there is an edge <tt>obj => a</tt> in one relation and another edge
	# <tt>a => b</tt> in another relation
	#
	# If +strict+ is true, +obj+ is not included in the returned set
	def children_of(obj, strict = true, relations = nil)
	    set = compute_children_of([obj].to_value_set, relations || self.relations)
	    set.delete(obj) if strict
	    set
	end

	def compute_children_of(current, relations)
	    old_size = current.size
	    for rel in relations
		next if (rel.parent && relations.include?(rel.parent))

		components = rel.generated_subgraphs(current, false)
		for c in components
		    current.merge c
		end
	    end

	    if current.size == old_size
		return current
	    else
		return compute_children_of(current, relations)
	    end
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
			:subsets => ValueSet.new,
			:noinfo => false,
			:graph => RelationGraph,
			:distribute => true,
			:dag => true,
			:single_child => false,
			:weak => false

	    # Check if this relation is already defined. If it is the case, reuse it.
	    # This is needed mostly by the reloading code
	    if const_defined?(options[:const_name])
		graph = const_get(options[:const_name])
		mod   = graph.support

	    else
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
		def each_#{options[:child_name]}
		    each_child_object(@@__r_#{relation_name}__) { |child| yield(child) }
		end
		def find_#{options[:child_name]}
		    each_child_object(@@__r_#{relation_name}__) do |child|
			return child if yield(child)
		    end
		    nil
		end
		EOD
	    else
		mod.class_eval <<-EOD
		def each_#{options[:child_name]}
		    each_child_object(@@__r_#{relation_name}__) do |child|
			yield(child, self[child, @@__r_#{relation_name}__])
		    end
		end
		def find_#{options[:child_name]}
		    each_child_object(@@__r_#{relation_name}__) do |child|
			return child if yield(child, self[child, @@__r_#{relation_name}__])
		    end
		    nil
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

