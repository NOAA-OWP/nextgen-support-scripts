wait                      # wait for background process to stop
ecflow_client --complete  # Notify ecFlow of a normal end
#sleep 65
trap 0                    # Remove all traps
exit 0                    # End the shell
