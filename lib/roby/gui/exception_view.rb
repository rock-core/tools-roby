module Roby
    module GUI
        class ExceptionRendering < MetaRuby::GUI::ExceptionRendering
            def filter_backtrace(parsed_backtrace, raw_backtrace)
                Roby.filter_backtrace(raw_backtrace, force: true)
            end

            def user_file?(file)
                Roby.app.app_file?(file)
            end
        end

        class ExceptionView < MetaRuby::GUI::ExceptionView
            def initialize(*)
                super
                @exception_rendering = ExceptionRendering.new(self.exception_rendering.linker)
            end

            def each_exception
                return enum_for(__method__) if !block_given?
                super do |e, reason|
                    yield(e, reason)
                    if e.respond_to?(:original_exceptions)
                        e.original_exceptions.each do |original_e|
                            yield(original_e, nil)
                        end
                    end
                end
            end
        end
    end
end
