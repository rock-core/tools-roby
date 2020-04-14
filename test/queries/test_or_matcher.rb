# frozen_string_literal: true

require 'roby/test/self'
require 'roby/tasks/simple'

module Roby
    module Queries
        describe OrMatcher do
            it 'combines task matchers' do
                t1 = Tasks::Simple.new_submodel { argument :id }.new(id: 1)
                t2 = Tasks::Simple.new_submodel { argument :id }.new(id: 2)
                t3 = Roby::Task.new
                plan.add [t1, t2, t3]

                query = (TaskMatcher.with_arguments(id: 1) |
                         TaskMatcher.with_arguments(id: 2))
                assert_equal [t1, t2].to_set, query.each_in_plan(plan).to_set
            end

            it 'combines an OR with a task matcher' do
                t1 = Tasks::Simple.new_submodel { argument :id }.new(id: 1)
                t2 = Tasks::Simple.new_submodel { argument :id }.new(id: 2)
                t2.executable = false
                t3 = Roby::Task.new
                plan.add [t1, t2, t3]

                query = (TaskMatcher.with_arguments(id: 1) |
                         TaskMatcher.with_arguments(id: 2) |
                         Roby::Task.match)
                assert_equal [t1, t2, t3].to_set, query.each_in_plan(plan).to_set
            end
        end
    end
end
