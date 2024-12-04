# frozen_string_literal: true

require "roby/test/self"
require "lib/roby/relations/incremental_transitive_closure.rb"

module Roby
    module Relations
        describe IncrementalTransitiveClosure do
            describe "#reachable?" do
                attr_reader :incremental_transitive_closure

                before do
                    @incremental_transitive_closure = IncrementalTransitiveClosure.new
                end

                describe "adding relations" do
                  it "adds vertex" do
                    incremental_transitive_closure.added_vertex(0)
                    assert incremental_transitive_closure.graph.has_vertex?(0)
                  end

                  it "adds edge between vertex" do
                    incremental_transitive_closure.added_vertex(0)
                    incremental_transitive_closure.added_vertex(1)
                    incremental_transitive_closure.added_edge(0,1)
                    assert incremental_transitive_closure.graph.has_edge?(0,1)
                  end

                  it "adds indirect edges between vertex" do
                    incremental_transitive_closure.added_vertex(0)
                    incremental_transitive_closure.added_vertex(1)
                    incremental_transitive_closure.added_vertex(2)
                    incremental_transitive_closure.added_edge(0,1)
                    incremental_transitive_closure.added_edge(1,2)
                    assert incremental_transitive_closure.graph.has_edge?(0,2)
                  end

                  it "tests reachability from direct and indirect vertex" do
                    incremental_transitive_closure.added_vertex(0)
                    incremental_transitive_closure.added_vertex(1)
                    incremental_transitive_closure.added_vertex(2)
                    incremental_transitive_closure.added_edge(0,1)
                    incremental_transitive_closure.added_edge(1,2)
                    assert incremental_transitive_closure.reachable?(0,2)
                    assert incremental_transitive_closure.reachable?(1,2)
                    refute incremental_transitive_closure.reachable?(2,1)
                    refute incremental_transitive_closure.reachable?(2,0)
                  end
                end
            end
        end
    end
end
