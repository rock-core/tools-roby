module Roby
    module Relations
        # A relation space is a module which handles a list of relations
        # (Relations::Graph instances) and applies them to a set of classes.
        # For instance, the TaskStructure relation space is defined by
        #   TaskStructure = Space(Task)
        #
        # See the files in roby/relations to see example definitions of new
        # relations
        #
        # Use Space#relation allow to define a new relation in a given
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
        class Space < Module
            # The set of relations included in this relation space
            attr_reader :relations
            # The set of classes on which the relations have been applied
            attr_reader :applied
            # The default graph class to be used for new relations. Defaults to
            # Relations::Graph
            attr_accessor :default_graph_class

            def initialize # :nodoc:
                @relations = Array.new
                @applied   = Array.new
                @default_graph_class = Relations::Graph
                super
            end

            def self.new_relation_graph_mapping
                Hash.new do |h, k|
                    if k
                        if k.kind_of?(Class)
                            known_relations = h.each_key.find_all { |rel| rel.kind_of?(Class) }
                            raise ArgumentError, "#{k} is not a known relation (known relations are #{known_relations.map { |o| "#{o.name}" }.join(", ")})"
                        elsif known_graph = h.fetch(k.class, nil)
                            raise ArgumentError, "it seems that you're trying to use the relation API to access a graph that is not part of this object's current plan. Given graph was #{k.object_id}, and the current graph for #{k.class} is #{known_graph.object_id}"
                        else
                            raise ArgumentError, "graph object #{known_graph} is not a known relation graph"
                        end
                    end
                end
            end

            # Instanciate this space's relation graphs
            #
            # It instanciates a graph per relation defined on self, and sets
            # their subset/superset relationships accordingly
            #
            # @param observer a graph observer object
            # @return [Hash<Models<Graph>,Graph>]
            def instanciate(observer: nil)
                graphs = self.class.new_relation_graph_mapping
                relations.each do |rel|
                    g = rel.new(observer: observer)
                    graphs[g] = graphs[rel] = g
                end
                relations.each do |rel|
                    rel.subsets.each do |subset_rel|
                        graphs[rel].superset_of(graphs[subset_rel])
                    end
                end
                graphs
            end

            # This relation applies on +klass+. It mainly means that a relation
            # defined on this Space will define the relation-access methods
            # and include its support module (if any) in +klass+. Note that the
            # {DirectedRelationSupport} module is automatically included in +klass+
            # as well.
            def apply_on(klass)
                klass.include DirectedRelationSupport
                klass.relation_spaces << self
                each_relation do |graph|
                    klass.include graph::Extension
                end
                applied << klass

                while klass
                    if klass.respond_to?(:all_relation_spaces)
                        klass.all_relation_spaces << self
                    end
                    klass = if klass.respond_to?(:supermodel) then klass.supermodel
                            end
                end
            end

            # Yields the relations that are defined on this space
            def each_relation
                return enum_for(__method__) if !block_given?
                relations.each do |rel|
                    yield(rel)
                end
            end

            # Yields the root relations that are defined on this space. A relation
            # is a root relation when it has no parent relation (i.e. it is the
            # subset of no other relations).
            def each_root_relation
                return enum_for(__method__) if !block_given?
                relations.each do |rel|
                    yield(rel) if !rel.parent
                end
            end

            # Returns the set of objects that are reachable from +obj+ in the union
            # graph of all the relations defined in this space. In other words, it
            # returns the set of vertices so that it exists a path starting at
            # +obj+ and ending at +v+ in the union graph of all the relations.
            # 
            # If +strict+ is true, +obj+ is not included in the returned set
            #
            # TODO: REIMPLEMENT
            def children_of(obj, strict = true, relations = nil)
                set = compute_children_of([obj].to_set, relations || self.relations.values)
                set.delete(obj) if strict
                set
            end

            # Internal implementation method for +children_of+
            #
            # TODO: REIMPLEMENT
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
            # subsets:: a list of subgraphs. See Relations::Graph#superset_of [empty set by default]
            # noinfo::
            #   wether the relation embeds some additional information. If false,
            #   the child iterator method (<tt>each_#{child_name}</tt>) will yield (child,
            #   info) instead of only child [false by default]
            # graph:: the relation graph class [Relations::Graph by default]
            # distribute:: if true, the relation can be seen by remote peers [true by default]
            # single_child::
            #   if the relations accepts only one child per vertex. If this option
            #   is set, defines a <tt>#{child_name}</tt> method which returns the
            #   only child (or nil if there is no child at all) [false by default]
            # dag::
            #   if true, {CycleFoundError} will be raised if a new vertex would
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
            # defines an instance of Relations::Graph which is a DAG, defining the
            # following methods on its vertices:
            #   each_children { |v, info| ... } => graph
            #   find_children { |v, info| ... } => object or nil
            #   add_children(v, info = nil) => graph
            #   remove_children(v) => graph
            #
            # and
            #
            #   relation :Children, child_name: :child
            #
            # would define
            #
            #   each_child { |v, info| ... } => graph
            #   find_child { |v, info| ... } => object or nil
            #   add_child(v, info = nil) => graph
            #   remove_child(v) => graph
            #
            # * the {DirectedRelationSupport} module gets included in the vertex classes at the
            #   construction of the Space instance. See #apply_on.
            # * the <tt>:noinfo</tt> option would then remove the 'info' parameter
            #   to the various blocks.
            # * if <tt>:single_child</tt> is set to true, then an additional method is defined:
            #     child => object or nil
            # * and finally if the following is used
            #     relation :Children, child_name: :child, parent_name: :parent
            #   then the following method is additionally defined
            #     each_parent { |v| ... }
            #
            # Finally, if a block is given, it gets included in the target class
            # (i.e. for a TaskStructure relation, Roby::Task)
            def relation(relation_name,
                            child_name:  relation_name.to_s.snakecase,
                            const_name:  relation_name,
                            parent_name: nil,
                            graph:       default_graph_class,
                            single_child: false,

                            distribute:  true,
                            dag:         true,
                            weak:        false,
                            strong:      false,
                            copy_on_replace: false,
                            noinfo:      false,
                            subsets:     Set.new,
                            **submodel_options)

                if block_given?
                    raise ArgumentError, "calling relation with a block is not supported anymore. Reopen #{const_name}::Extension after the relation call to add helper methods"
                elsif strong && weak
                    raise ArgumentError, "a relation cannot be both strong and weak"
                end

                # Check if this relation is already defined. If it is the case, reuse it.
                # This is needed mostly by the reloading code
                graph_class = define_or_reuse(const_name) do
                    klass = graph.new_submodel(
                        distribute: distribute, dag: dag, weak: weak, strong: strong,
                        copy_on_replace: copy_on_replace, noinfo: noinfo, subsets: subsets,
                        child_name: child_name, **submodel_options)
                    synthetized_methods = Module.new do
                        define_method("__r_#{relation_name}__") { self.relation_graphs[klass] }
                    end
                    extension = Module.new
                    class_extension = Module.new
                    klass.const_set("SynthetizedMethods", synthetized_methods)
                    klass.const_set("Extension", extension)
                    klass.const_set("ModelExtension", class_extension)
                    extension.const_set("ClassExtension", class_extension)
                    klass
                end
                subsets.each do |subset_rel|
                    graph_class.superset_of(subset_rel)
                end
                synthetized_methods = graph_class::SynthetizedMethods
                extension = graph_class::Extension
                applied.each do |klass|
                    klass.include synthetized_methods
                    klass.include extension
                end

                if parent_name
                    synthetized_methods.class_eval <<-EOD,  __FILE__, __LINE__ + 1
                    def each_#{parent_name}(&iterator)
                        return enum_for(__method__) if !iterator
                        self.each_parent_object(__r_#{relation_name}__, &iterator)
                    end
                    EOD
                end

                if noinfo
                    synthetized_methods.class_eval <<-EOD,  __FILE__, __LINE__ + 1
                    def each_#{child_name}(&iterator)
                        return enum_for(__method__) if !iterator
                        each_child_object(__r_#{relation_name}__, &iterator)
                    end
                    def find_#{child_name}(&block)
                        each_child_object(__r_#{relation_name}__).find(&block)
                    end
                    EOD
                else
                    synthetized_methods.class_eval <<-EOD,  __FILE__, __LINE__ + 1
                    def enum_#{child_name}
                        Roby.warn_deprecated "enum_#{child_name} is deprecated, use each_#{child_name} instead"
                        each_#{child_name}
                    end
                    def each_#{child_name}(with_info = true)
                        return enum_for(__method__, with_info) if !block_given?
                        if with_info
                            each_child_object(__r_#{relation_name}__) do |child|
                                yield(child, self[child, __r_#{relation_name}__])
                            end
                        else
                            each_child_object(__r_#{relation_name}__, &proc)
                        end
                    end
                    def find_#{child_name}(with_info = true)
                        if with_info
                            each_child_object(__r_#{relation_name}__) do |child|
                                return child if yield(child, self[child, __r_#{relation_name}__])
                            end
                        else
                            each_child_object(__r_#{relation_name}__).find(&proc)
                        end
                        nil
                    end
                    EOD
                end

                synthetized_methods.class_eval <<-EOD,  __FILE__, __LINE__ + 1
                def add_#{child_name}(to, info = nil)
                    add_child_object(to, __r_#{relation_name}__, info)
                    self
                end
                def remove_#{child_name}(to)
                    remove_child_object(to, __r_#{relation_name}__)
                    self
                end

                def adding_#{child_name}_parent(parent, info)
                end
                def added_#{child_name}_parent(parent, info)
                end
                def removing_#{child_name}_parent(parent)
                end
                def removed_#{child_name}_parent(parent)
                end
                def updating_#{child_name}_parent(parent, info)
                end
                def updated_#{child_name}_parent(parent, info)
                end

                def adding_#{child_name}(child, info)
                end
                def added_#{child_name}(child, info)
                end
                def removing_#{child_name}(child)
                end
                def removed_#{child_name}(child)
                end
                def updating_#{child_name}(child, info)
                end
                def updated_#{child_name}(child, info)
                end
                EOD

                if single_child
                    synthetized_methods.class_eval do
                        define_method child_name do
                            if task = instance_variable_get("@#{child_name}")
                                plan[task]
                            end
                        end
                    end
                    graph_class.class_eval do
                        attr_reader :single_child_accessor

                        def add_edge(parent, child, info)
                            super
                            parent.instance_variable_set single_child_accessor, child
                        end

                        def update_single_child_accessor(object, expected_object)
                            current_object = object.instance_variable_get single_child_accessor
                            if current_object == expected_object
                                object.instance_variable_set single_child_accessor,
                                    each_out_neighbour(object).first
                            end
                        end

                        def remove_edge(parent, child)
                            super
                            update_single_child_accessor(parent, child)
                        end

                        def remove_vertex(object)
                            parents = in_neighbours(object)
                            super
                            parents.each do |parent|
                                update_single_child_accessor(parent, object)
                            end
                        end
                    end
                end

                add_relation(graph_class)
                graph_class
            end

            def add_relation(rel)
                relations << rel
                Relations.add_relation(rel)
            end

            # Remove +rel+ from the set of relations managed in this space
            def remove_relation(rel)
                relations.delete(rel)
                Relations.remove_relation(rel)
            end
        end
    end
end

