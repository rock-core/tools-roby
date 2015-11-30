module Roby
    # A plan that is used as a template to inject in other plans
    class TemplatePlan < Plan
        def template?; true end
        def executable?; false end
    end
end
