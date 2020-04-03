# frozen_string_literal: true

require 'roby/test/self'
require 'roby/tasks/simple'

module Roby
    module Queries
        describe NotMatcher do
            it 'negates a task matcher' do
                t1 = Tasks::Simple.new_submodel { argument :id }.new(id: 1)
                t2 = Tasks::Simple.new_submodel { argument :id }.new(id: 2)
                t3 = Roby::Task.new
                plan.add [t1, t2, t3]

                query = TaskMatcher.with_arguments(id: 1).negate
                assert_kind_of NotMatcher::Tasks, query
                assert_equal [t2, t3].to_set, query.each_in_plan(plan).to_set
            end
        end
    end
end
