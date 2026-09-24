#!/usr/bin/env python3
"""
Verify audit logs for Phase 02A tests
"""

import os
import requests
import json

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_SECRET_KEY = os.getenv("SUPABASE_SECRET_KEY")

# Organization ID from the last test run
ORG_A_ID = "b71e71c4-9b44-4b91-a6da-e99f5186e248"

def query_audit_logs(org_id):
    """Query audit logs via PostgREST with service role"""
    url = f"{SUPABASE_URL}/rest/v1/audit_logs"
    headers = {
        "apikey": SUPABASE_SECRET_KEY,
        "Authorization": f"Bearer {SUPABASE_SECRET_KEY}",
        "Content-Type": "application/json"
    }
    params = {
        "organization_id": f"eq.{org_id}",
        "order": "created_at.desc",
        "limit": "50"
    }
    
    try:
        response = requests.get(url, headers=headers, params=params, timeout=30)
        if response.status_code == 200:
            logs = response.json()
            return logs
        else:
            print(f"❌ Failed to query audit logs: {response.status_code}")
            print(f"Response: {response.text}")
            return None
    except Exception as e:
        print(f"❌ Error querying audit logs: {e}")
        return None

def main():
    print("="*80)
    print("  AUDIT LOGS VERIFICATION")
    print("="*80)
    print(f"\nQuerying audit logs for Org A: {ORG_A_ID}\n")
    
    logs = query_audit_logs(ORG_A_ID)
    
    if logs is None:
        print("❌ Failed to retrieve audit logs")
        return False
    
    print(f"✅ Retrieved {len(logs)} audit log entries\n")
    
    # Count actions
    action_counts = {}
    for log in logs:
        action = log.get('action')
        action_counts[action] = action_counts.get(action, 0) + 1
    
    print("Audit log summary:")
    for action, count in sorted(action_counts.items()):
        print(f"  - {action}: {count}")
    
    print("\n" + "="*80)
    print("  VERIFICATION RESULTS")
    print("="*80 + "\n")
    
    # Check for expected actions
    expected_actions = {
        'RESERVATION_CREATED': 3,  # At least 3 (TEST 01, 03, 04)
        'RESERVATION_CANCELLED': 1,  # At least 1 (TEST 04)
        'TIME_BLOCK_CREATED': 1,  # At least 1 (TEST 05)
    }
    
    all_passed = True
    for action, min_count in expected_actions.items():
        actual_count = action_counts.get(action, 0)
        if actual_count >= min_count:
            print(f"✅ {action}: {actual_count} (expected at least {min_count})")
        else:
            print(f"❌ {action}: {actual_count} (expected at least {min_count})")
            all_passed = False
    
    if all_passed:
        print("\n✅ ALL AUDIT LOG CHECKS PASSED")
    else:
        print("\n❌ SOME AUDIT LOG CHECKS FAILED")
    
    # Print recent logs for inspection
    print("\n" + "="*80)
    print("  RECENT AUDIT LOGS (last 10)")
    print("="*80 + "\n")
    
    for i, log in enumerate(logs[:10], 1):
        print(f"{i}. {log.get('action')} - {log.get('entity_type')} - {log.get('created_at')}")
        if log.get('metadata'):
            print(f"   Metadata: {json.dumps(log.get('metadata'))}")
    
    return all_passed

if __name__ == "__main__":
    success = main()
    exit(0 if success else 1)
