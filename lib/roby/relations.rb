require "roby/relations/bidirectional_directed_adjacency_graph"
require 'rgl/traversal'
require 'rgl/topsort'
require "roby/relations/models/directed_relation_support"
require "roby/relations/fork_merge_visitor"
require "roby/relations/directed_relation_support"
require "roby/relations/models/graph"
require "roby/relations/graph"
require "roby/relations/event_relation_graph"
require "roby/relations/models/task_relation_graph"
require "roby/relations/task_relation_graph"
require "roby/relations/space"

module Roby
    module Relations
        # This exception is raised when an edge is being added in a DAG, while this
        # edge would create a cycle.
        class CycleFoundError < RuntimeError; end

        class << self
            attr_reader :all_relations
        end
        @all_relations = Array.new

        def self.each_graph_topologically(graphs)
            rel_to_graph = Hash[*graphs.flat_map { |g| [g.class, g] }]
            all_relations.each do |rel|
                if g = rel_to_graph[rel]
                    yield(g)
                end
            end
        end

        def self.add_relation(rel)
            sorted_relations = Array.new

            # Remove from the set of relations the ones that are not leafs
            remaining = self.all_relations
            remaining << rel
            target_size = remaining.size

            while sorted_relations.size != target_size
                queue, remaining = remaining.partition { |g| !g.subsets.intersect?(remaining.to_set) }
                sorted_relations.concat(queue)
            end

            @all_relations = sorted_relations
        end

        def self.remove_relation(rel)
            all_relations.delete(rel)
        end
    end

    # Creates a new relation space which applies on +klass+. If a block is
    # given, it is eval'd in the context of the new relation space instance
    def self.RelationSpace(klass)
        klass.include Relations::DirectedRelationSupport
        klass.extend  Relations::Models::DirectedRelationSupport
        relation_space = Relations::Space.new
        relation_space.apply_on klass
        relation_space
    end
end

