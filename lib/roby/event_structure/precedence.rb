# frozen_string_literal: true

require "roby/relations/incremental_transitive_closure"

module Roby
    module EventStructure
        relation :Precedence, subsets: [CausalLink], noinfo: true

        # Graph class that holds the precedence information
        class Precedence < Relations::EventRelationGraph
            attr_reader :incremental_transitive_closure

            def initialize( # rubocop:disable Metrics/ParameterLists
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
                    observer: observer,
                    distribute: distribute,
                    dag: dag,
                    weak: weak,
                    strong: strong,
                    copy_on_replace: copy_on_replace,
                    noinfo: noinfo,
                    subsets: subsets
                )
                @incremental_transitive_closure =
                    Relations::IncrementalTransitiveClosure.new
            end

            def remove_edge(source, target)
                super(source, target)
                @incremental_transitive_closure.removed_edge(source, target)
            end

            def remove_vertex(object)
                super(object)
                @incremental_transitive_closure.removed_vertex(object)
            end

            def reachable?(source, target)
                @incremental_transitive_closure.reachable?(source, target, self)
            end
        end
    end
end
