import Darwin
import TUFFServerCore

exit(await RouterServerCommand.main(Array(CommandLine.arguments.dropFirst())))
