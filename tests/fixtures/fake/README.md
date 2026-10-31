Stand-ins for the Python tools, which tests/commands_test.sh puts first on the
import path of the stand-in interpreters (the project's environment and the
tool environments the orb's install would make). Each records its call in
$STUB_DIR/calls, as the shell stand-ins do, and answers as the settings in
its environment say. They are not the real tools and never run in CI jobs
that use the real ones.
