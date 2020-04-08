# frozen_string_literal: true

module Roby
    # Basic disposable adaptor for blocks and other disposables
    class Disposable
        def initialize(*disposables, &block)
            @disposables = disposables
            @block = block
            @disposed = false
        end

        def disposed?
            @disposed
        end

        def dispose
            return if disposed?

            @disposables.delete_if do |d|
                d.dispose
                true
            end
            @block&.call
            @disposed = true
        end

        class Null
            def disposed?
                true
            end

            def dispose; end
        end
    end

    def self.disposable(*disposables, &block)
        Disposable.new(*disposables, &block)
    end

    def self.null_disposable
        Disposable::Null.new
    end
end
