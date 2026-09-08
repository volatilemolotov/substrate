# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""TTFI (time to first instruction) benchmark runtime flags.

The resume mode is not declared here: TTFI reuses --resume-mode from
common/resume_mode.py, because the choice it describes is the same one
(call ResumeActor first, or let router traffic wake the actor).
"""

from locust import events
from locust.argument_parser import LocustArgumentParser


@events.init_command_line_parser.add_listener
def add_ttfi_arguments(parser: LocustArgumentParser) -> None:
    group = parser.add_argument_group("TTFI Benchmark")
    group.add_argument(
        "--ttfi-timeout",
        type=float,
        default=60.0,
        help="Seconds to keep retrying the first instruction before recording the "
        "window as a failure (default: 60)",
    )
    group.add_argument(
        "--ttfi-template",
        type=str,
        default="glutton",
        help="ActorTemplate whose activation is measured (default: glutton). Point "
        "it at a template on another sandbox class or snapshot scope to compare them",
    )
    group.add_argument(
        "--ttfi-cold-source",
        type=str,
        default="golden",
        choices=["golden", "coldboot"],
        help="What supplies the guest state on a cold start: 'golden' (default) "
        "restores the template's golden snapshot; 'coldboot' skips it and starts "
        "the containers from the OCI image. Applies to --resume-mode explicit "
        "only, since the flag rides on the ResumeActor RPC",
    )
