#!/usr/bin/env bash
set -euo pipefail

# Configuration
n=1
remote_host="192.168.0.252"
remote_user="ubuntu4"
network_interface="eth0"
input_yaml="p1.yaml"
output_yaml="p1-updated.yaml"

# Read cumulative NIC IRQ counts per CPU and select cores above n * mean
bounded_cores=$(ssh "${remote_user}@${remote_host}" \
    "python3 - '$network_interface' '$n'" <<'PY'
import sys

interface = sys.argv[1]
n = float(sys.argv[2])

with open('/proc/interrupts', 'r', encoding='utf-8') as f:
    lines = f.readlines()

cpu_ids = [int(x[3:]) for x in lines[0].split() if x.startswith('CPU')]
if not cpu_ids:
    raise SystemExit('Error: CPU columns not found in /proc/interrupts')

interrupts = {cpu: 0 for cpu in cpu_ids}
matched = 0
for line in lines[1:]:
    if ':' not in line:
        continue
    _, rest = line.split(':', 1)
    if interface not in rest:
        continue
    matched += 1
    fields = rest.split()
    for idx, cpu in enumerate(cpu_ids):
        if idx < len(fields) and fields[idx].isdigit():
            interrupts[cpu] += int(fields[idx])

if matched == 0:
    raise SystemExit(f'Error: no IRQ lines found for {interface}')

average = sum(interrupts.values()) / len(interrupts)
threshold = average * n
bounded = [cpu for cpu, count in interrupts.items() if count > threshold]

print(f'Average IRQ count: {average:.2f}', file=sys.stderr)
print(f'Threshold (n={n}): {threshold:.2f}', file=sys.stderr)
for cpu, count in interrupts.items():
    print(f'CPU {cpu}: {count}', file=sys.stderr)

print(' '.join(map(str, bounded)))
PY
)

if [[ -z "$bounded_cores" ]]; then
    echo 'Error: No bounded cores found' >&2
    exit 1
fi

echo "Bounded cores: $bounded_cores"
read -r -a bounded_core_array <<< "$bounded_cores"
if (( ${#bounded_core_array[@]} < 2 )); then
    echo 'Error: Fewer than two bounded cores found' >&2
    exit 1
fi

slo1=${bounded_core_array[0]}
slo2=${bounded_core_array[1]}

cp "$input_yaml" "$output_yaml"
SLO1="$slo1" SLO2="$slo2" yq -i \
    '.metadata.annotations."example.com/SLO1" = strenv(SLO1) | .metadata.annotations."example.com/SLO2" = strenv(SLO2)' \
    "$output_yaml"

echo "SLO1: $slo1"
echo "SLO2: $slo2"
echo "Updated YAML file saved to $output_yaml"
