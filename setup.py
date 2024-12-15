import subprocess
import os

def run_vcpkg_command(command):
    """Runs a vcpk command and returns the output.

    Args:
        command: The vcpk command to execute.

    Returns:
        The output of the command.
    """

    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running vcpk command: {result.stderr}")
        return None
    return result.stdout

# Install vcpkg
vcpkg_command = ["git", "clone", "https://github.com/iowarp/iowarp-install"]
output = run_vcpkg_command(vcpkg_command)
print(output)

os.chdir("./iowarp-install/")

# List installed packages
vcpkg_command = ["./install.sh"]
# vcpkg_command = ["ls"]
output = run_vcpkg_command(vcpkg_command)
print(output)

# Customize the command as needed
# vcpkg_command = ["vcpkg", "integrate", "install"]
# output = run_vcpkg_command(vcpkg_command)
# print(output)
