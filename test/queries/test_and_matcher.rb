# frozen_string_literal: true

require 'roby/test/self'
require 'roby/tasks/simple'

module Roby
    module Queries
        describe AndMatcher do
            it 'combines task matchers' do
                t1 = Tasks::Simple.new_submodel { argument :id }.new(id: 1)
                t2 = Tasks::Simple.new_submodel { argument :id }.new(id: 2)
                t3 = Roby::Task.new
                plan.add [t1, t2, t3]

                query = (TaskMatcher.fully_instanciated & TaskMatcher.executable)
                assert_equal [t1, t2].to_set, query.each_in_plan(plan).to_set

                query = (TaskMatcher.fully_instanciated &
                        TaskMatcher.executable.with_arguments(id: 1))
                assert_equal [t1].to_set, query.each_in_plan(plan).to_set

                query = (TaskMatcher.fully_instanciated & TaskMatcher.abstract)
                assert_equal [t3].to_set, query.each_in_plan(plan).to_set
            end

            it 'combines an AND of task matchers with a task matcher' do
                t1 = Tasks::Simple.new_submodel { argument :id }.new(id: 1)
                t2 = Tasks::Simple.new_submodel { argument :id }.new(id: 2)
                t3 = Roby::Task.new
                plan.add [t1, t2, t3]

                query = (TaskMatcher.fully_instanciated &
                         TaskMatcher.executable &
                         TaskMatcher.with_arguments(id: 1))
                assert_equal [t1], query.each_in_plan(plan).to_a
            end
        end
    end
end
