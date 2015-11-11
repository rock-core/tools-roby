require 'utilrb/object/scoped_eval'
module Roby
    # This exception is raised when an edge is being added in a DAG, while this
    # edge would create a cycle.
    class CycleFoundError < RuntimeError; end

    # Base support for relations. It is mixed in objects on which a
    # RelationSpace applies on, like Task for TaskStructure and EventGenerator
    # for EventStructure.
    #
    # See also the definition of RelationGraph#add_relation and
    # RelationGraph#remove_relation for the possibility to define hooks that
    # get called when a new edge involving +self+ as a vertex gets added and
    # removed 
    module DirectedRelationSupport
	include BGL::Vertex

	alias :child_object?	    :child_vertex?
	alias :parent_object?	    :parent_vertex?
	alias :related_object?	    :related_vertex?
	alias :each_child_object    :each_child_vertex
	alias :each_parent_object   :each_parent_vertex

        def each_relation
            each_graph do |g|
                yield(g) if g.kind_of?(RelationGraph)
            end
        end

        def each_root_relation
            each_graph do |g|
                yield(g) if g.kind_of?(RelationGraph) && g.root_relation?
            end
        end

        def sorted_relations
            Roby.all_relations.
                find_all { |rel| rel.include?(self) }
        end

        # Yields each relation this vertex is part of, starting with the most
        # specialized relations
        def each_relation_sorted
            # Remove from the set of relations the ones that are not leafs
            for rel in sorted_relations
                yield(rel)
            end
        end

	# Removes +self+ from all the graphs it is included in.
	def clear_vertex
            for rel in sorted_relations
                rel.remove(self)
            end
	end
        alias :clear_relations :clear_vertex

        ##
        # :method: enum_relations => enumerator
        # Returns an Enumerator object for the set of relations this object is
        # included in. The same enumerator instance is always returned.
	cached_enum("relation", "relations", false)
        ##
        # :method: enum_parent_objects(relation) => enumerator
        # Returns an Enumerator object for the set of parents this object has
        # in +relation+. The same enumerator instance is always returned.
	cached_enum("parent_object", "parent_objects", true)
        ##
        # :method: enum_child_objects(relation) => enumerator
        # Returns an Enumerator object for the set of children this object has
        # in +relation+. The same enumerator instance is always returned.
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

        # Remove all edges in which +self+ is the source and +child+ the
        # target. If +relation+ is given, it removes only the edge in that
        # relation graph.
	def remove_child_object(child, relation = nil)
            if !relation
                for rel in sorted_relations
                    rel.remove_relation(self, child)
                end
            else
                relation.remove_relation(self, child)
            end
	end

        # Remove all edges in which +self+ is the source. If +relation+
        # is given, it removes only the edges in that relation graph.
	def remove_children(relation = nil)
            if !relation
                for rel in sorted_relations
                    remove_children(rel)
                end
                return
            end

            children = child_objects(relation).to_a
            for child in children
                remove_child_object(child, relation)
            end
	end

        # Remove all edges in which +child+ is the source and +self+ the
        # target. If +relation+ is given, it removes only the edge in that
        # relation graph.
	def remove_parent_object(parent, relation = nil)
	    parent.remove_child_object(self, relation)
	end

        # Remove all edges in which +self+ is the target. If +relation+
        # is given, it removes only the edges in that relation graph.
	def remove_parents(relation = nil)
            if !relation
                for rel in sorted_relations
                    remove_parents(rel)
                end
                return
            end

            parents = parent_objects(relation).to_a
            for parent in parents
                remove_parent_object(relation, parent)
            end
	end

	# Remove all relations that point to or come from +to+ If +to+ is nil,
	# it removes all edges in which +self+ is involved.
        #
        # If +relation+ is not nil, only edges of that relation graph are removed.
	def remove_relations(relation = nil)
            if !relation
                for rel in sorted_relations
                    remove_relations(rel)
                end
                return
            elsif !relation.include?(self)
                return
            end

            each_parent_object(relation) do |parent|
                relation.remove_relation(parent, self)
            end

            each_child_object(relation) do |child|
                relation.remove_relation(self, child)
            end
	end

        def []=(object, relation, value)
            super

            if respond_to?(:updated_edge_info)
                updated_edge_info(object, relation, value)
            end
            if relation.respond_to?(:updated_info)
	        relation.updated_info(self, object, value)
	    end
        end
    end

    # This class manages the graph defined by an object relation in Roby.
    # 
    # Relation graphs are managed in hierarchies (for instance, in
    # EventStructure, Precedence is a superset of CausalLink, and CausalLink a
    # superset of both Forwarding and Signal). In this hierarchy, at each
    # level, an edge cannot be present in more than one graph. Nonetheless, it
    # is possible for a parent relation to have an edge which is present in
    # none of its children.
    #
    # Each relation define two things:
    # * a graph, which is represented by the RelationGraph instance itself
    # * support methods that are defined on the vertices of the relation. They 
    #   allow to manage the vertex in its relations easily. Those methods are
    #   defined in a separate module (see {#support})
    #
    # In general, relations are part of a RelationSpace instance, which manages
    # the set of relations whose vertices are of the same kind (for instance
    # TaskStructure manages all relations whose vertices are Task instances).
    # In these cases, RelationSpace#relation allow to define new relations easily.
    class RelationGraph < BGL::Graph
	# The relation name
	attr_reader   :name
	# The relation parent (if any). See #superset_of.
	attr_accessor :parent
	# The set of graphs that are directly children of self in the graph
        # hierarchy. They are subgraphs of self, but not all the existing
        # subgraphs of self. See {#recursive_subsets} to get all subsets
	attr_reader   :subsets
        # The set of all graphs that are known to be subgraphs of self
        attr_reader :recursive_subsets
	# The graph options as given to RelationSpace#relation
	attr_reader   :options

        # Creates a relation graph with the given name and options. The
        # following options are recognized:
	# +dag+:: 
        #   if the graph is a DAG. If true, add_relation will check that
	#   no cycle is created
	# +subsets+:: 
        #   a set of RelationGraph objects that are children of this one.
        #   See #superset_of.
	# +distributed+:: 
        #   if this relation graph should be seen by remote hosts
	def initialize(name, options = {})
            self.name = name
	    @name    = name
	    @options = options
	    @subsets = ValueSet.new
            @recursive_subsets = ValueSet.new
	    @distribute = options[:distribute]
	    @dag     = options[:dag]
	    @weak    = options[:weak]
            @strong  = options[:strong]
            @copy_on_replace = options[:copy_on_replace]
            @embeds_info = !options[:noinfo]

	    if options[:subsets]
		options[:subsets].each(&method(:superset_of))
	    end
	end

	# True if this relation graph is a DAG
	attr_predicate :dag
	# True if this relation should be seen by remote peers
	attr_predicate :distribute
        # If this relation is weak. Weak relations can be removed without major
        # consequences. This is mainly used during plan garbage collection to
        # break cross-relations cycles (cycles which exist in the graph union
        # of all the relation graphs).
	attr_predicate :weak
        # If this relation is strong. Strong relations mark parts of the plan
        # that can't be exchanged bit-by-bit. I.e. plan.replace_task will ignore
        # those relations.
        attr_predicate :strong
        # If this relation embeds some additional information
        attr_predicate :embeds_info?
        # If true, a task A that is being replaced by a task B will *not* have
        # the links in this relation graph removed. Instead, they simply get
        # copied to A
        attr_predicate :copy_on_replace

	def to_s; name end

	# True if this relation does not have a parent
	def root_relation?; !parent end

        # Remove +vertex+ from this graph. It removes all relations that
        # +vertex+ is part of, and calls the corresponding hooks
        def remove(vertex)
            return if !self.include?(vertex)
            vertex.remove_relations(self)
            super
        end

        # Add an edge between +from+ and +to+. The relation is added on all
        # parent relation graphs as well. If #dag? is true on +self+ or on one
        # of its parents, the method will raise CycleFoundError in case the new
        # edge would create a cycle.
        #
        # If +from+ or +to+ define the following hooks:
        #   adding_parent_object(parent, relations, info)
        #   adding_child_object(child, relations, info)
        #   added_parent_object(parent, relations, info)
        #   added_child_object(child, relations, info)
        #
        # then these hooks get respectively called before and after having
        # added the relation, where +relations+ is the set of RelationGraph
        # instances where the edge has been added. It can be either [+self+] if
        # the edge does not already exist in it, or [+self+, +parent+,
        # <tt>parent.parent</tt>, ...] if the parent, grandparent, ... graphs
        # do not include the edge either.
	def add_relation(from, to, info = nil)
	    # Get the toplevel DAG in our relation hierarchy. We only test for the
	    # DAG property on this one, as it is the union of all its children
	    top_dag = nil
	    new_relations = []
	    rel     = self
	    while rel
		top_dag = rel if rel.dag?
                if !rel.linked?(from, to)
                    new_relations << rel
                end
		rel = rel.parent
	    end
	    if top_dag && !top_dag.linked?(from, to) && top_dag.reachable?(to, from)
		raise CycleFoundError, "cannot add a #{from} -> #{to} relation since it would create a cycle"
	    end

	    # Now check that we're not changing the edge info. This is ignored
            # if +self+ has the noinfo flag set.
            if linked?(from, to)
                if !(old_info = from[to, self]).nil?
                    if old_info != info && !(info = merge_info(from, to, old_info, info))
                        raise ArgumentError, "trying to change edge information in #{self} for #{from} => #{to}: old was #{old_info} and new is #{info}"
                    end
                end
                from[to, self] = info
                return
            end

	    if !new_relations.empty?
		if from.respond_to?(:adding_child_object)
		    from.adding_child_object(to, new_relations, info)
		end
		if to.respond_to?(:adding_parent_object)
		    to.adding_parent_object(from, new_relations, info)
		end

		for rel in new_relations
		    rel.__bgl_link(from, to, (info if self == rel))
		end

		if from.respond_to?(:added_child_object)
		    from.added_child_object(to, new_relations, info)
		end
		if to.respond_to?(:added_parent_object)
		    to.added_parent_object(from, new_relations, info)
		end
	    end
	end

        def updated_info(from, to, info)
            super if defined? super
        end

        def merge_info(from, to, old, new)
            super if defined? super
        end

	alias :__bgl_link :link

	# Unlike BGL::Graph#link, it is possible to "add" a link between two
        # objects that are already linked. Two cases
        #
        # * the 'info' parameter is identical, in which case nothing is done
        # * the 'info' parameter is different. #merge_info is called on the
        #   relation object. If it returns a non-nil object, then it is used
        #   as an updated info, otherwise, an error is generated.
	def link(from, to, info)
	    if linked?(from, to)
                old_info = from[to, self]
		if info != old_info
                    if info = merge_info(from, to, old_info, info)
                        from[to, self] = info
                        return
                    else
                        raise ArgumentError, "trying to change edge information"
                    end
		end
		return
	    end
	    super(from, to, info)
	end

        # Remove the relation between +from+ and +to+, in this graph and in its
        # parent graphs as well.
        #
        # If +from+ or +to+ define the following hooks:
        #   removing_parent_object(parent, relations)
        #   removing_child_object(child, relations)
        #   removed_parent_object(parent, relations)
        #   removed_child_object(child, relations)
        #
        # then these hooks get respectively called once before and once after
        # having removed the relation, where +relations+ is the set of
        # RelationGraph instances where the edge has been removed. It is always
        # <tt>[self, parent, parent.parent, ...]</tt> up to the root relation
        # which is a superset of +self+.
	def remove_relation(from, to)
            if !linked?(from, to)
                return
            end

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
        #
        # See also #superset_of
	def subset?(relation)
	    self.eql?(relation) || subsets.any? { |subrel| subrel.subset?(relation) }
	end

	# Returns +true+ if there is an edge +source+ -> +target+ in this graph
	# or in one of its parents
        #
        # See #superset_of for a description of the parent mechanism
	def linked_in_hierarchy?(source, target)
	    linked?(source, target) || (parent.linked?(source, target) if parent)
	end

	# Declare that +self+ is a superset of +relation+. Once this is done,
        # the system manages two constraints:
        # * all new relations added in +relation+ are also added in +self+
        # * it is not allowed for an edge to exist in two different subsets of
        #   +self+
        # * of course, if +self+ is a DAG, then in effect +relation+ is constrained
        #   to be one as well.
        #
        # One single graph can be the superset of multiple subgraphs (these are
        # stored in the #subsets attribute), but one graph can have only one
        # parent (#parent).
	def superset_of(relation)
	    relation.each_edge do |source, target, info|
		if linked_in_hierarchy?(source, target)
		    raise ArgumentError, "relation and self already share an edge"
		end
	    end

	    relation.parent = self
	    subsets << relation
            recompute_recursive_subsets

	    # Copy the relations of the child into this graph
	    relation.each_edge do |source, target, info|
		source.add_child_object(target, self, info)
	    end
	end

	# The Ruby module that gets included in graph objects
	attr_accessor :support

        # Recomputes the recursive_subsets attribute, and triggers the
        # recomputation on its parents as well
        def recompute_recursive_subsets
            @recursive_subsets = subsets.inject(ValueSet.new) do |set, child|
                set.merge(child.recursive_subsets)
            end
            if parent
                parent.recompute_recursive_subsets
            end
        end
    end

    # Subclass of RelationSpace for events. Its main usage is to keep track of
    # which tasks are related in a given relation through their events.
    #
    # I.e. if events 'a' and 'b' are parts of the tasks ta and tb, and 
    #
    #   a -> b
    #
    # in this relation graph, then 
    #
    #   relation.related_tasks?(ta, tb)
    #
    # will return true
    class EventRelationGraph < RelationGraph
        # The graph of tasks related to each other by their events
        attr_reader :task_graph

        def initialize(*args)
            super
            @task_graph = BGL::Graph.new
        end

        def __bgl_link(from, to, info)
            super

            if from.respond_to?(:task) && to.respond_to?(:task)
                from_task, to_task = from.task, to.task
                if from_task != to_task && !task_graph.linked?(from_task, to_task)
                    task_graph.link(from_task, to_task, nil)
                end
            end
        end

        def remove(event)
            super
            if event.respond_to?(:task)
                task_graph.remove(event.task)
            end
        end

        def unlink(from, to)
            super
            if from.respond_to?(:task) && to.respond_to?(:task)
                task_graph.unlink(from.task, to.task)
            end
        end

        def related_tasks?(ta, tb)
            task_graph.linked?(ta, tb)
        end
    end

    # Subclass of RelationSpace for tasks.
    #
    # It adds attributes that are specific to tasks
    class TaskRelationGraph < RelationGraph
        # If true, the tasks that have a parent in this relation will still be
        # available for scheduling. Otherwise, they won't get scheduled
        attr_predicate :scheduling?, true

        def initialize(*args)
            super
            if options.has_key?(:scheduling)
                @scheduling = options[:scheduling]
            else
                @scheduling = true
            end
        end
    end

    # A relation space is a module which handles a list of relations
    # (RelationGraph instances) and applies them to a set of classes.
    # For instance, the TaskStructure relation space is defined by
    #   TaskStructure = RelationSpace(Task)
    #
    # See the files in roby/relations to see example definitions of new
    # relations
    #
    # Use RelationSpace#relation allow to define a new relation in a given
    # space. For instance, one can either do
    #
    #   TaskStructure.relation :NewRelation
    #
    # or
    #
    #   module TaskStructure
    #       relation :NewRelation
    #   end
    #
    # This relation can then be referenced by
    # <tt>TaskStructure::NewRelation</tt>
    class RelationSpace < Module
	# The set of relations included in this relation space
	attr_reader :relations
	# The set of classes on which the relations have been applied
	attr_reader :applied
        # The default graph class to be used for new relations. Defaults to
        # RelationGraph
        attr_accessor :default_graph_class

	def initialize # :nodoc:
	    @relations = Array.new
	    @applied   = Array.new
            @default_graph_class = RelationGraph
	    super
	end

        # This relation applies on +klass+. It mainly means that a relation
        # defined on this RelationSpace will define the relation-access methods
        # and include its support module (if any) in +klass+. Note that the
        # DirectedRelationSupport module is automatically included in +klass+
        # as well.
	def apply_on(klass)
	    klass.include DirectedRelationSupport
	    each_relation do |graph|
		klass.include graph.support
	    end

	    applied << klass
	end

	# Yields the relations that are defined on this space
	def each_relation
	    for rel in relations
		yield(rel)
	    end
	end

        # Yields the root relations that are defined on this space. A relation
        # is a root relation when it has no parent relation (i.e. it is the
        # subset of no other relations).
	def each_root_relation
	    for rel in relations
		yield(rel) unless rel.parent
	    end
	end

        # Returns the set of objects that are reachable from +obj+ in the union
        # graph of all the relations defined in this space. In other words, it
        # returns the set of vertices so that it exists a path starting at
        # +obj+ and ending at +v+ in the union graph of all the relations.
        # 
	# If +strict+ is true, +obj+ is not included in the returned set
	def children_of(obj, strict = true, relations = nil)
	    set = compute_children_of([obj].to_value_set, relations || self.relations)
	    set.delete(obj) if strict
	    set
	end

        # Internal implementation method for +children_of+
	def compute_children_of(current, relations) # :nodoc:
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

        # Defines a relation in this relation space. This defines a relation
        # graph, and various iteration methods on the vertices.  If a block is
        # given, it defines a set of functions which should additionally be
        # defined on the vertex objects.
        #
        # The valid options are:
	#
	# child_name::
	#   define a <tt>each_#{child_name}</tt> method to iterate
	#   on the vertex children. Uses the relation name by default (a Child
	#   relation would define a <tt>each_child</tt> method)
	# parent_name::
	#   define a <tt>each_#{parent_name}</tt> method to iterate
	#   on the parent vertices. If none is given, no method is defined.
	# subsets:: a list of subgraphs. See RelationGraph#superset_of [empty set by default]
	# noinfo::
	#   wether the relation embeds some additional information. If false,
	#   the child iterator method (<tt>each_#{child_name}</tt>) will yield (child,
	#   info) instead of only child [false by default]
	# graph:: the relation graph class [RelationGraph by default]
	# distribute:: if true, the relation can be seen by remote peers [true by default]
	# single_child::
        #   if the relations accepts only one child per vertex. If this option
        #   is set, defines a <tt>#{child_name}</tt> method which returns the
        #   only child (or nil if there is no child at all) [false by default]
        # dag::
        #   if true, CycleFoundError will be raised if a new vertex would
        #   create a cycle in this relation [true by default]
        # weak::
        #   marks that this relation might be broken by the plan manager if
        #   needs be. This is currently only used in the garbage collection
        #   phase to decide in which order to GC the tasks. I.e. if a cycle is
        #   found, the weak relations will be broken to resolve it.
        # strong::
        #   marks that the tasks that are linked by this relation should not be
        #   torn apart. This is for instance used in the replacement operation,
        #   which will never "move" a relation from the original task to the
        #   replaced one.
        #
        # For instance,
        #   relation :Children
        #
        # defines an instance of RelationGraph which is a DAG, defining the
        # following methods on its vertices:
        #   each_children { |v, info| ... } => graph
        #   find_children { |v, info| ... } => object or nil
        #   add_children(v, info = nil) => graph
        #   remove_children(v) => graph
        #
        # and
        #
        #   relation :Children, :child_name => :child
        #
        # would define
        #
        #   each_child { |v, info| ... } => graph
        #   find_child { |v, info| ... } => object or nil
        #   add_child(v, info = nil) => graph
        #   remove_child(v) => graph
        #
        # * the DirectedRelationSupport module gets included in the vertex classes at the
        #   construction of the RelationSpace instance. See #apply_on.
        # * the <tt>:noinfo</tt> option would then remove the 'info' parameter
        #   to the various blocks.
        # * if <tt>:single_child</tt> is set to true, then an additional method is defined:
        #     child => object or nil
        # * and finally if the following is used
        #     relation :Children, :child_name => :child, :parent_name => :parent
        #   then the following method is additionally defined
        #     each_parent { |v| ... }
        #
        # Finally, if a block is given, it gets included in the target class
        # (i.e. for a TaskStructure relation, Roby::Task)
	def relation(relation_name, options = {}, &block)
	    options = validate_options options,
			:child_name  => relation_name.to_s.snakecase,
			:const_name  => relation_name,
			:parent_name => nil,
			:subsets     => ValueSet.new,
			:noinfo      => false,
			:graph       => default_graph_class,
			:distribute  => true,
			:dag         => true,
			:single_child => false,
			:weak        => false,
                        :strong      => false,
                        :copy_on_replace => false

            if options[:strong] && options[:weak]
                raise ArgumentError, "a relation cannot be both strong and weak"
            end

	    # Check if this relation is already defined. If it is the case, reuse it.
	    # This is needed mostly by the reloading code
            graph = define_or_reuse(options[:const_name]) do
                klass = Class.new(options[:graph])
		graph = klass.new "#{self.name}::#{options[:const_name]}", options
		mod = Module.new do
		    singleton_class.class_eval do
			define_method("__r_#{relation_name}__") { graph }
		    end
		    class_eval "@@__r_#{relation_name}__ = __r_#{relation_name}__"
		end
                const_set("#{options[:const_name]}GraphClass", klass)
                klass.const_set("Extension", mod)
                mod.const_set("ClassExtension", Module.new)
                klass.const_set("ModelExtension", mod::ClassExtension)
		relations << graph
                graph.support = mod
                graph
	    end
            mod = graph.support
            mod.scoped_eval(:module_eval, &block) if block

	    if parent_enumerator = options[:parent_name]
		mod.class_eval <<-EOD,  __FILE__, __LINE__ + 1
		def each_#{parent_enumerator}(&iterator)
                    if !block_given?
                        return enum_parent_objects(@@__r_#{relation_name}__)
                    end

		    self.each_parent_object(@@__r_#{relation_name}__, &iterator)
		end
		EOD
	    end

	    if options[:noinfo]
		mod.class_eval <<-EOD,  __FILE__, __LINE__ + 1
		def each_#{options[:child_name]}
                    if !block_given?
                        return enum_child_objects(@@__r_#{relation_name}__)
                    end

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
		mod.class_eval <<-EOD,  __FILE__, __LINE__ + 1
                cached_enum("#{options[:child_name]}", "#{options[:child_name]}", true)
		def each_#{options[:child_name]}(with_info = true)
                    if !block_given?
                        return enum_#{options[:child_name]}(with_info)
                    end

                    if with_info
                        each_child_object(@@__r_#{relation_name}__) do |child|
                            yield(child, self[child, @@__r_#{relation_name}__])
                        end
                    else
                        each_child_object(@@__r_#{relation_name}__) do |child|
                            yield(child)
                        end
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
	    mod.class_eval <<-EOD,  __FILE__, __LINE__ + 1
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
                existing_methods = mod.instance_methods(false).map(&:to_sym)
                has_add_child_hook    = existing_methods.include?(:added_child_object)
                has_remove_child_hook = existing_methods.include?(:removed_child_object)

		mod.class_eval <<-EOD,  __FILE__, __LINE__ + 1
		attr_reader :#{options[:child_name]}

                #{"alias __added_child_object__ added_child_object" if has_add_child_hook}
                def added_child_object(child, relations, info)
                    if relations.include?(@@__r_#{relation_name}__)
                        instance_variable_set :@#{options[:child_name]}, child
                    end

                    super if defined? super
                    #{"__added_child_object__(child, relations, info)" if has_add_child_hook}
                end

                #{"alias __removed_child_object__ removed_child_object" if has_remove_child_hook}
                def removed_child_object(child, relations)
                    if relations.include?(@@__r_#{relation_name}__)
                        instance_variable_set :@#{options[:child_name]}, nil
		    	each_child_object(@@__r_#{relation_name}__) do |child|
                            instance_variable_set :@#{options[:child_name]}, child
			    break
			end
                    end
                    super if defined? super

                    #{"__removed_child_object__(child, relations)" if has_remove_child_hook}
                end
		EOD
	    end

	    graph.support = mod
	    applied.each { |klass| klass.include mod }

            Roby.add_relation(graph)

	    graph
	end

        # Remove +rel+ from the set of relations managed in this space
        def remove_relation(rel)
            relations.delete(rel)
            Roby.remove_relation(rel)
        end
    end

    class << self
        attr_reader :all_relations
    end
    @all_relations = Array.new

    def self.add_relation(rel)
        sorted_relations = Array.new

        # Remove from the set of relations the ones that are not leafs
        remaining = self.all_relations.to_value_set
        remaining << rel
        target_size = remaining.size

        while sorted_relations.size != target_size
            queue, remaining = remaining.partition { |g| !g.subsets.intersects?(remaining.to_value_set) }
            sorted_relations.concat(queue)
        end

        @all_relations = sorted_relations
    end

    def self.remove_relation(rel)
        all_relations.delete(rel)
    end

    # Creates a new relation space which applies on +klass+. If a block is
    # given, it is eval'd in the context of the new relation space instance
    def self.RelationSpace(klass)
	klass.include DirectedRelationSupport
	relation_space = RelationSpace.new
        relation_space.apply_on klass
        relation_space
    end
end

