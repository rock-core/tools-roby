# frozen_string_literal: true

module Roby
    module CLI
        # Base class for all exceptions that are considered the user's fault by
        # the CLI
        class CLIException < RuntimeError
        end

        # The user passed wrong arguments to a command
        class CLIInvalidArguments < CLIException
        end

        # The CLI command failed
        class CLICommandFailed < CLIException
        end
    end
end
