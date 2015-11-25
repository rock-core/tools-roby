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

            # This relation applies on +klass+. It mainly means that a relation
            # defined on this Space will define the relation-access methods
            # and include its support module (if any) in +klass+. Note that the
            # {DirectedRelationSupport} module is automatically included in +klass+
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
                set = compute_children_of([obj].to_set, relations || self.relations)
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
            def relation(relation_name, options = {})
                options = validate_options options,
                            child_name:  relation_name.to_s.snakecase,
                            const_name:  relation_name,
                            parent_name: nil,
                            subsets:     Set.new,
                            noinfo:      false,
                            graph:       default_graph_class,
                            distribute:  true,
                            dag:         true,
                            single_child: false,
                            weak:        false,
                            strong:      false,
                            copy_on_replace: false

                if block_given?
                    raise ArgumentError, "calling relation with a block is not supported anymore. Reopen #{options[:const_name]}GraphClass::Extension after the relation call to add helper methods"
                elsif options[:strong] && options[:weak]
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
                def adding_child_object(to, relations, info)
                    super
                    if relations.include?(@@__r_#{relation_name}__)
                        adding_#{options[:child_name]}(to, info)
                    end
                end
                def removing_child_object(to, relations)
                    super
                    if relations.include?(@@__r_#{relation_name}__)
                        removing_#{options[:child_name]}(to)
                    end
                end
                def add_#{options[:child_name]}(to, info = nil)
                    add_child_object(to, @@__r_#{relation_name}__, info)
                    self
                end
                def remove_#{options[:child_name]}(to)
                    remove_child_object(to, @@__r_#{relation_name}__)
                    self
                end

                def adding_#{options[:child_name]}(to, info)
                end
                def added_#{options[:child_name]}(to, info)
                end
                def removing_#{options[:child_name]}(to)
                end
                def removed_#{options[:child_name]}(to)
                end
                EOD

                if options[:single_child]
                    mod.class_eval <<-EOD,  __FILE__, __LINE__ + 1
                    attr_reader :#{options[:child_name]}

                    def added_child_object(child, relations, info)
                        if relations.include?(@@__r_#{relation_name}__)
                            instance_variable_set :@#{options[:child_name]}, child
                        end
                        super if defined? super
                        if relations.include?(@@__r_#{relation_name}__)
                            added_#{options[:child_name]}(child, info)
                        end
                    end

                    def removed_child_object(child, relations)
                        if relations.include?(@@__r_#{relation_name}__)
                            instance_variable_set :@#{options[:child_name]}, nil
                            each_child_object(@@__r_#{relation_name}__) do |child|
                                instance_variable_set :@#{options[:child_name]}, child
                                break
                            end
                        end
                        super if defined? super
                        if relations.include?(@@__r_#{relation_name}__)
                            removed_#{options[:child_name]}(child)
                        end
                    end
                    EOD
                else
                    mod.class_eval <<-EOD, __FILE__, __LINE__ + 1
                    def added_child_object(to, relations, info)
                        super
                        if relations.include?(@@__r_#{relation_name}__)
                            added_#{options[:child_name]}(to, info)
                        end
                    end
                    def removed_child_object(to, relations)
                        super
                        if relations.include?(@@__r_#{relation_name}__)
                            removed_#{options[:child_name]}(to)
                        end
                    end
                    EOD
                end

                graph.support = mod
                applied.each { |klass| klass.include mod }

                Roby::Relations.add_relation(graph)

                graph
            end

            # Remove +rel+ from the set of relations managed in this space
            def remove_relation(rel)
                relations.delete(rel)
                Roby::Relations.remove_relation(rel)
            end
        end
    end
end

