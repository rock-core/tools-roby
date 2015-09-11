module Roby
    module GUI
        class ExceptionView < MetaRuby::GUI::ExceptionView
            def filter_backtrace(backtrace)
                Roby.filter_backtrace(backtrace, force: true)
            end

            def user_file?(file)
                Roby.app.app_file?(file)
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
