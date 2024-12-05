# frozen_string_literal: true

require "roby/relations/incremental_transitive_closure.rb"

module Roby
    module EventStructure
        relation :Precedence, subsets: [CausalLink], noinfo: true

        # Graph class that holds the precedence information
        class Precedence < Relations::EventRelationGraph
            attr_reader :incremental_transitive_closure

            def initialize(
                observer: nil,
                distribute: self.class.distribute?,
                dag: self.class.dag?,
                weak: self.class.weak?,
                strong: self.class.strong?,
                copy_on_replace: self.class.copy_on_replace?,
                noinfo: !self.class.embeds_info?,
                subsets: Set.new
            )
                super(
                    observer:observer,
                    distribute:distribute,
                    dag:dag,
                    weak:weak,
                    strong:strong,
                    copy_on_replace:copy_on_replace,
                    noinfo:noinfo,
                    subsets:subsets
                )
                @incremental_transitive_closure =
                    Relations::IncrementalTransitiveClosure.new
            end

            def add_vertex(object)
                super(object)
                @incremental_transitive_closure.added_vertex(object)
            end


            def add_edge(a, b, info)
                super(a, b, info)
                @incremental_transitive_closure.added_edge(a, b)
            end


            def remove_edge(source,target)
                super(source,target)
                @incremental_transitive_closure.removed_edge(source,target)
            end

            def remove_vertex(object)
                super(object)
                @incremental_transitive_closure.removed_vertex(object)
            end

            def reachable?(source,target)
                return true if @incremental_transitive_closure.reachable?(source,target)
                depth_first_visit(source) do |visited_vertex|
                    return true if visited_vertex == target
                    @incremental_transitive_closure.added_vertex(visited_vertex)
                    adjacent_vertices(visited_vertex).each do |adjecent_vertex|
                        @incremental_transitive_closure.added_vertex(adjecent_vertex)
                        @incremental_transitive_closure.added_edge(visited_vertex, adjecent_vertex)
                    end
                end
            end
        end
    end
end
