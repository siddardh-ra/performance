#!/usr/bin/env python3
"""
OpenTelemetry Metrics Validation Tool

This script validates the presence of all expected OpenTelemetry metrics
after migration from OpenCensus (Epic SRVKP-7899).

Usage:
    python3 validate-otel-metrics.py \
        --reference config/otel-metrics-reference.json \
        --collected artifacts/otel-metrics-raw.json \
        --output artifacts/otel-metrics-validation.json \
        --report artifacts/otel-metrics-report.txt \
        --deployment-version 1.23.0

"""

import argparse
import json
import sys
from datetime import datetime
from typing import Dict, List, Set, Tuple


class Colors:
    """ANSI color codes for terminal output"""
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    BOLD = '\033[1m'
    NC = '\033[0m'  # No Color


def load_json(file_path: str) -> dict:
    """Load JSON file"""
    try:
        with open(file_path, 'r') as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"{Colors.RED}ERROR{Colors.NC}: File not found: {file_path}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"{Colors.RED}ERROR{Colors.NC}: Invalid JSON in {file_path}: {e}", file=sys.stderr)
        sys.exit(1)


def expand_metric_names(metric: dict) -> List[str]:
    """
    Expand a metric definition into all possible metric names including suffixes.

    For example, a histogram metric "foo" with suffixes ["_bucket", "_sum", "_count"]
    will expand to ["foo_bucket", "foo_sum", "foo_count"]
    """
    base_name = metric['name']
    suffixes = metric.get('suffixes', [])

    if not suffixes:
        # No suffixes, just return the base name
        return [base_name]

    # Expand with all suffixes
    return [f"{base_name}{suffix}" for suffix in suffixes]


def build_expected_metrics(reference: dict, install_results: bool = False) -> Dict[str, List[str]]:
    """
    Build a dictionary of expected metrics from the reference file.

    Returns:
        Dict[component_name, List[metric_names]]
    """
    expected = {}

    # Pipelines Controller
    if 'pipelines_controller' in reference:
        metrics = []
        for metric in reference['pipelines_controller']['metrics']:
            metrics.extend(expand_metric_names(metric))
        expected['pipelines_controller'] = metrics

    # Chains Controller
    if 'chains_controller' in reference:
        metrics = []
        for metric in reference['chains_controller']['metrics']:
            metrics.extend(expand_metric_names(metric))
        expected['chains_controller'] = metrics

    # Tekton Results (only if installed)
    if install_results and 'tekton_results' in reference:
        metrics = []
        for metric in reference['tekton_results']['metrics']:
            metrics.extend(expand_metric_names(metric))
        expected['tekton_results'] = metrics

    # Common runtime metrics
    if 'common_runtime_metrics' in reference:
        metrics = []
        for metric in reference['common_runtime_metrics']['metrics']:
            metrics.extend(expand_metric_names(metric))
        expected['common_runtime'] = metrics

    return expected


def validate_metrics(expected: Dict[str, List[str]], collected: dict) -> Dict[str, dict]:
    """
    Validate collected metrics against expected metrics.

    Returns:
        Dict[component_name, {
            'total_expected': int,
            'total_found': int,
            'metrics_found': List[str],
            'metrics_missing': List[str],
            'sample_values': Dict[metric_name, value]
        }]
    """
    results = {}

    for component, expected_metrics in expected.items():
        expected_set = set(expected_metrics)
        collected_metrics = collected.get(component, {})
        collected_set = set(collected_metrics.keys())

        found_metrics = expected_set & collected_set
        missing_metrics = expected_set - collected_set

        # Get sample values for found metrics
        sample_values = {}
        for metric in list(found_metrics)[:10]:  # Sample first 10 found metrics
            sample_values[metric] = collected_metrics.get(metric, {})

        results[component] = {
            'total_expected': len(expected_set),
            'total_found': len(found_metrics),
            'metrics_found': sorted(list(found_metrics)),
            'metrics_missing': sorted(list(missing_metrics)),
            'sample_values': sample_values,
            'coverage_percentage': round((len(found_metrics) / len(expected_set) * 100), 2) if expected_set else 0
        }

    return results


def generate_text_report(validation_results: dict, deployment_version: str) -> str:
    """Generate a human-readable text report"""

    report_lines = []
    report_lines.append("=" * 80)
    report_lines.append("OpenTelemetry Metrics Validation Report")
    report_lines.append(f"OpenShift Pipelines Version: {deployment_version}")
    report_lines.append(f"Validation Date: {datetime.now().isoformat()}")
    report_lines.append("=" * 80)
    report_lines.append("")

    metadata = validation_results.get('validation_metadata', {})

    # Overall summary
    total_expected = 0
    total_found = 0
    total_missing = 0

    for component, results in validation_results.items():
        if component == 'validation_metadata':
            continue
        total_expected += results['total_expected']
        total_found += results['total_found']
        total_missing += len(results['metrics_missing'])

    report_lines.append("OVERALL SUMMARY")
    report_lines.append("-" * 80)
    report_lines.append(f"Total Metrics Expected:  {total_expected}")
    report_lines.append(f"Total Metrics Found:     {total_found}")
    report_lines.append(f"Total Metrics Missing:   {total_missing}")
    coverage = (total_found / total_expected * 100) if total_expected > 0 else 0
    report_lines.append(f"Overall Coverage:        {coverage:.2f}%")
    report_lines.append("")

    # Per-component details
    for component, results in validation_results.items():
        if component == 'validation_metadata':
            continue

        report_lines.append("")
        report_lines.append("=" * 80)
        report_lines.append(f"Component: {component.replace('_', ' ').title()}")
        report_lines.append("=" * 80)
        report_lines.append(f"Expected Metrics:  {results['total_expected']}")
        report_lines.append(f"Found Metrics:     {results['total_found']}")
        report_lines.append(f"Missing Metrics:   {len(results['metrics_missing'])}")
        report_lines.append(f"Coverage:          {results['coverage_percentage']:.2f}%")
        report_lines.append("")

        if results['metrics_missing']:
            report_lines.append("CRITICAL - Missing Metrics:")
            report_lines.append("-" * 80)
            for metric in results['metrics_missing']:
                report_lines.append(f"  ❌ {metric}")
            report_lines.append("")
        else:
            report_lines.append("✅ All expected metrics are present!")
            report_lines.append("")

        if results['metrics_found']:
            report_lines.append(f"Found Metrics (showing first 20 of {len(results['metrics_found'])}):")
            report_lines.append("-" * 80)
            for metric in results['metrics_found'][:20]:
                report_lines.append(f"  ✅ {metric}")
            if len(results['metrics_found']) > 20:
                report_lines.append(f"  ... and {len(results['metrics_found']) - 20} more")
            report_lines.append("")

    # Validation status
    report_lines.append("")
    report_lines.append("=" * 80)
    report_lines.append("VALIDATION STATUS")
    report_lines.append("=" * 80)
    if total_missing == 0:
        report_lines.append("✅ PASSED - All expected OpenTelemetry metrics are present")
    else:
        report_lines.append(f"❌ FAILED - {total_missing} metrics are missing")
        report_lines.append("")
        report_lines.append("Action Required:")
        report_lines.append("  1. Review the missing metrics list above")
        report_lines.append("  2. Verify the deployment version is correct (v1.23.0+)")
        report_lines.append("  3. Check controller logs for metric registration errors")
        report_lines.append("  4. Ensure workload was executed (some metrics only appear under load)")
    report_lines.append("=" * 80)
    report_lines.append("")

    return "\n".join(report_lines)


def main():
    parser = argparse.ArgumentParser(
        description='Validate OpenTelemetry metrics for Tekton Pipelines v1.23.0+',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument('--reference', required=True,
                        help='Path to reference metrics JSON file')
    parser.add_argument('--collected', required=True,
                        help='Path to collected metrics JSON file')
    parser.add_argument('--output', required=True,
                        help='Path to output validation JSON file')
    parser.add_argument('--report', required=True,
                        help='Path to output text report file')
    parser.add_argument('--deployment-version', default='1.23.0',
                        help='OpenShift Pipelines deployment version')
    parser.add_argument('--install-results', action='store_true',
                        help='Include Tekton Results metrics in validation')
    parser.add_argument('-d', '--debug', action='store_true',
                        help='Enable debug output')

    args = parser.parse_args()

    if args.debug:
        print(f"{Colors.BLUE}DEBUG{Colors.NC}: Loading reference metrics from {args.reference}")

    # Load reference and collected metrics
    reference = load_json(args.reference)
    collected = load_json(args.collected)

    if args.debug:
        print(f"{Colors.BLUE}DEBUG{Colors.NC}: Building expected metrics list")

    # Build expected metrics
    expected_metrics = build_expected_metrics(reference, args.install_results)

    if args.debug:
        total_expected = sum(len(metrics) for metrics in expected_metrics.values())
        print(f"{Colors.BLUE}DEBUG{Colors.NC}: Total expected metrics: {total_expected}")
        for component, metrics in expected_metrics.items():
            print(f"{Colors.BLUE}DEBUG{Colors.NC}:   {component}: {len(metrics)} metrics")

    # Validate metrics
    validation_results = validate_metrics(expected_metrics, collected)

    # Add metadata
    validation_results['validation_metadata'] = {
        'osp_version': args.deployment_version,
        'validation_timestamp': datetime.now().isoformat(),
        'otel_validation_mode': True,
        'install_results': args.install_results
    }

    # Write JSON output
    with open(args.output, 'w') as f:
        json.dump(validation_results, f, indent=2)

    print(f"{Colors.GREEN}✅ Validation JSON written to: {args.output}{Colors.NC}")

    # Generate and write text report
    text_report = generate_text_report(validation_results, args.deployment_version)
    with open(args.report, 'w') as f:
        f.write(text_report)

    print(f"{Colors.GREEN}✅ Text report written to: {args.report}{Colors.NC}")

    # Print summary to stdout
    print("")
    print("=" * 80)
    print("VALIDATION SUMMARY")
    print("=" * 80)

    total_expected = 0
    total_found = 0
    total_missing = 0

    for component, results in validation_results.items():
        if component == 'validation_metadata':
            continue
        total_expected += results['total_expected']
        total_found += results['total_found']
        total_missing += len(results['metrics_missing'])

        status_icon = "✅" if results['coverage_percentage'] == 100 else "❌"
        print(f"{status_icon} {component}: {results['total_found']}/{results['total_expected']} ({results['coverage_percentage']:.1f}%)")

    print("-" * 80)
    coverage = (total_found / total_expected * 100) if total_expected > 0 else 0
    status_icon = "✅" if total_missing == 0 else "❌"
    print(f"{status_icon} OVERALL: {total_found}/{total_expected} ({coverage:.1f}%)")
    print("=" * 80)

    # Exit code based on validation result
    if total_missing > 0:
        print(f"\n{Colors.RED}❌ VALIDATION FAILED{Colors.NC}: {total_missing} metrics missing")
        sys.exit(1)
    else:
        print(f"\n{Colors.GREEN}✅ VALIDATION PASSED{Colors.NC}: All metrics present")
        sys.exit(0)


if __name__ == '__main__':
    main()
