module Roby
    module Relations
        module Models
            module Graph
                include MetaRuby::ModelAsClass

                # @api private
                #
                # Hook method called to setup a new relation graph
                def setup_submodel(submodel, distribute: true, dag: false, weak: false, strong: false, copy_on_replace: false, noinfo: true, subsets: Set.new)
                    super
                    submodel.distribute = distribute
                    submodel.dag = dag
                    submodel.weak = weak
                    submodel.strong = strong
                    submodel.copy_on_replace = copy_on_replace
                    submodel.embeds_info = !noinfo
                    submodel.instance_variable_set :@subsets, Set.new
                    submodel.instance_variable_set :@parent, nil
                    subsets.each do |rel|
                        submodel.superset_of(rel)
                    end
                end

                attr_predicate :distribute?, true
                attr_predicate :dag?, true
                attr_predicate :weak?, true
                attr_predicate :strong?, true
                attr_predicate :copy_on_replace?, true
                attr_predicate :embeds_info?, true


                # The set of graphs that are subsets of self
                #
                # @return [Set<Graph>]
                attr_reader :subsets

                # The one and only graph that is a superset of self
                #
                # @return [Graph,nil]
                attr_reader :parent

                # Sets the graph that is a superset of self
                #
                # @raise [ArgumentError] if there is already one
                def parent=(rel)
                    if @parent && @parent != rel
                        raise ArgumentError, "#{self} already has a parent (#{@parent})"
                    end
                    @parent = rel
                end

                # True if this relation graph is the subset of no other relation
                def root_relation?
                    !parent
                end

                # Declare that self is a superset of another graph
                #
                # @param [Graph] rel
                def superset_of(rel)
                    subsets << rel
                    rel.parent = self
                end
            end
        end
    end
end

