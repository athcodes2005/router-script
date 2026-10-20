#!/usr/bin/env python3
"""Generate Google service prefixes using Google's documented goog-minus-cloud method."""
import argparse
import ipaddress
import json
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]

def service_ranges(google, cloud):
    result = []
    for version, key in [(4, 'ipv4Prefix'), (6, 'ipv6Prefix')]:
        prefixes = list(ipaddress.collapse_addresses(ipaddress.ip_network(p[key]) for p in google['prefixes'] if key in p))
        excludes = list(ipaddress.collapse_addresses(ipaddress.ip_network(p[key]) for p in cloud['prefixes'] if key in p))
        for exclude in excludes:
            remaining = []
            for network in prefixes:
                if network.subnet_of(exclude):
                    continue
                if exclude.subnet_of(network):
                    remaining.extend(network.address_exclude(exclude))
                else:
                    remaining.append(network)
            prefixes = remaining
        result.extend(ipaddress.collapse_addresses(prefixes))
    if not result or any(not net.is_global or net.prefixlen == 0 for net in result):
        raise ValueError('Invalid/empty Google public-service prefix set')
    return sorted(result, key=lambda n: (n.version, int(n.network_address), n.prefixlen))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--goog-file', type=Path)
    parser.add_argument('--cloud-file', type=Path)
    args = parser.parse_args()
    feeds = {}
    for name in ['goog', 'cloud']:
        source = getattr(args, name + '_file')
        if source:
            feeds[name] = json.loads(source.read_text())
        else:
            with urlopen(f'https://www.gstatic.com/ipranges/{name}.json', timeout=20) as response:
                feeds[name] = json.load(response)
    ranges = service_ranges(feeds['goog'], feeds['cloud'])
    content = '# Google service prefixes: goog.json minus cloud.json\n'
    content += '# Source: https://www.gstatic.com/ipranges/{goog,cloud}.json\n'
    content += '# Feed creation: ' + str(feeds['goog'].get('creationTime', 'unknown')) + '\n'
    content += ''.join(str(net) + '\n' for net in ranges)
    target = ROOT / 'google_service_ranges.txt'
    staging = target.with_suffix('.tmp')
    staging.write_text(content)
    staging.replace(target)
    print(f'Wrote {len(ranges)} Google service ranges')

if __name__ == '__main__':
    main()
