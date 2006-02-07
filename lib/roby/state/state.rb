module Roby
    class ExtendableStruct
        def initialize(attach_to = nil, attach_name = nil)
            @members = Hash.new
            if attach_to
                @attach = lambda { attach_to.send("#{attach_name}=", self) } 
            end
        end
        def attach
            return unless @attach
            @attach.call
            @attach = nil
        end
        
        def respond_to?(name)
            return true if super
            name = name.to_s
            if name[-1] == ?=
                @members.has_key?(name[0..-2])
            else
                @members.has_key?(name) 
            end
        end
        def method_missing(name, *args, &proc)
            attach
            name = name.to_s
            if name[-1] == ?= # Setter
                if stable?
                    super
                else
                    @members[name[0..-2]] = args.first
                end
            else # update
                member = @members[name]
                member ||= ExtendableStruct.new(self, name) unless stable?
                super unless member

                if member.respond_to?(:update)
                    member.update(*args, &proc)
                else
                    member
                end
            end
        end

        def update(hash = nil)
            attach
            hash.each { |k, v| send("#{k}=", v) } if hash
            yield(self) if block_given?
            self
        end

        def stable?; @stable end
        def stable!(recursive = false)
            @stable = true
            if recursive
                @members.each { |name, object| object.stable!(recursive) if object.respond_to?(:stable!) }
            end
        end
    end

    State = ExtendableStruct.new
end

