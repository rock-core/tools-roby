require 'roby/droby'

Exception.extend  Roby::DRoby::V5::Builtins::ClassDumper
Exception.extend  Roby::DRoby::Identifiable
Exception.include Roby::DRoby::V5::Builtins::ExceptionDumper
Array.include     Roby::DRoby::V5::Builtins::ArrayDumper
Hash.include      Roby::DRoby::V5::Builtins::HashDumper
Set.include       Roby::DRoby::V5::Builtins::SetDumper

class Module
    def droby_dump(dest)
        raise "can't dump modules (#{self})"
    end
end
class Class
    def droby_dump(dest)
        raise "can't dump class #{self}"
    end
end

class NilClass
    def droby_id
    end
end

module Roby
    class ExceptionBase
        include DRoby::V5::ExceptionBaseDumper
    end
    class LocalizedError
        include DRoby::V5::LocalizedErrorDumper
    end
    class PlanningFailedError
        include DRoby::V5::PlanningFailedErrorDumper
    end
    class ExecutionException
        include DRoby::V5::ExecutionExceptionDumper
    end
    module Relations
        class Graph
            extend DRoby::Identifiable
            extend DRoby::V5::DRobyConstant::Dump
        end
    end
    module Models
        class TaskServiceModel
            include DRoby::Identifiable
            include DRoby::V5::Models::TaskServiceModelDumper
        end
    end
    class Event
        include DRoby::V5::EventDumper
    end

    class PlanObject
        include DRoby::Identifiable
    end

    class EventGenerator
        extend DRoby::Identifiable
        extend DRoby::V5::DRobyConstant::Dump
        include DRoby::V5::EventGeneratorDumper
    end

    class TaskArguments
        include DRoby::V5::TaskArgumentsDumper
    end

    class Task
        extend DRoby::Identifiable
        extend DRoby::V5::Models::TaskDumper
        include DRoby::V5::TaskDumper
    end
    class TaskEventGenerator
        include DRoby::V5::TaskEventGeneratorDumper
    end
    class DelayedArgumentFromObject
        extend DRoby::V5::Builtins::ClassDumper
        include DRoby::V5::DelayedArgumentFromObjectDumper
    end
    class Plan
        include DRoby::Identifiable
        include DRoby::V5::PlanDumper
    end

    module Actions
        class Action
            include DRoby::V5::Actions::ActionDumper
        end
        class Interface
            extend DRoby::Identifiable
            extend DRoby::V5::ModelDumper
        end
        module Models
            class Action
                include DRoby::V5::Actions::Models::ActionDumper
                class Argument
                    include DRoby::V5::Actions::Models::Action::ArgumentDumper
                end
            end
        end
    end

    module Queries
        class AndMatcher
            include DRoby::V5::Queries::AndMatcherDumper
        end

        class ExecutionExceptionMatcher
            include DRoby::V5::Queries::ExecutionExceptionMatcherDumper
        end

        class LocalizedErrorMatcher
            include DRoby::V5::Queries::LocalizedErrorMatcherDumper
        end

        class NotMatcher
            include DRoby::V5::Queries::NotMatcherDumper
        end

        class OrMatcher
            include DRoby::V5::Queries::OrMatcherDumper
        end

        class PlanObjectMatcher
            include DRoby::V5::Queries::PlanObjectMatcherDumper
        end

        class TaskMatcher
            include DRoby::V5::Queries::TaskMatcherDumper
        end

        class Query
            include DRoby::V5::Queries::QueryDumper
        end
    end
end

