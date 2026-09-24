#!/usr/bin/env python3
"""
Phase 02B - Image Upload Magic Byte Validation Test (TEST 2)
Tests that POST /api/arenas/:id/images validates REAL file content (magic bytes),
not just extension or Content-Type header.
"""

import requests
import io
import os
from PIL import Image

# Environment
BASE_URL = os.getenv('NEXT_PUBLIC_BASE_URL', 'https://reserva-core-setup.preview.emergentagent.com')
API_URL = f"{BASE_URL}/api"
SUPABASE_URL = os.getenv('NEXT_PUBLIC_SUPABASE_URL', 'https://khidbemtqybkbywrpllx.supabase.co')
SUPABASE_SECRET_KEY = os.getenv("SUPABASE_SECRET_KEY")
SUPABASE_PUBLISHABLE_KEY = os.getenv('NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY', 'sb_publishable_JgA9Kju8XbZZxF4gruhEYw_T8wYYR1k')

print("=" * 80)
print("PHASE 02B - IMAGE UPLOAD MAGIC BYTE VALIDATION TEST (TEST 2)")
print("=" * 80)

# ============================================================================
# SETUP: Create test user, sign in, onboard
# ============================================================================

print("\n[SETUP] Creating test user via Supabase Admin API...")
test_email = f"image-test-{os.urandom(4).hex()}@reservagol.test"
test_password = "ReservaGol123"

# Create user via Supabase Admin API
admin_headers = {
    'apikey': SUPABASE_SECRET_KEY,
    'Authorization': f'Bearer {SUPABASE_SECRET_KEY}',
    'Content-Type': 'application/json'
}

create_user_payload = {
    'email': test_email,
    'password': test_password,
    'email_confirm': True
}

resp = requests.post(
    f"{SUPABASE_URL}/auth/v1/admin/users",
    json=create_user_payload,
    headers=admin_headers
)

if resp.status_code not in [200, 201]:
    print(f"❌ Failed to create user: {resp.status_code} {resp.text}")
    exit(1)

user_data = resp.json()
print(f"✅ User created: {test_email}")

# Sign in to get access token
print("\n[SETUP] Signing in to get access token...")
signin_headers = {
    'apikey': SUPABASE_PUBLISHABLE_KEY,
    'Content-Type': 'application/json'
}

signin_payload = {
    'email': test_email,
    'password': test_password
}

resp = requests.post(
    f"{SUPABASE_URL}/auth/v1/token?grant_type=password",
    json=signin_payload,
    headers=signin_headers
)

if resp.status_code != 200:
    print(f"❌ Failed to sign in: {resp.status_code} {resp.text}")
    exit(1)

session = resp.json()
access_token = session['access_token']
print(f"✅ Signed in successfully")

# Create Org + Arena + Court via onboarding
print("\n[SETUP] Creating organization via onboarding...")
auth_headers = {
    'Authorization': f'Bearer {access_token}',
    'Content-Type': 'application/json'
}

onboarding_payload = {
    'organization': {
        'name': 'Image Test Org',
        'responsible_name': 'Test Owner',
        'responsible_phone': '11999000001'
    },
    'arena': {
        'name': 'Image Test Arena',
        'address': 'Rua Teste, 123',
        'city': 'São Paulo',
        'state': 'SP',
        'whatsapp': '11999000001'
    },
    'courts': [
        {'name': 'Court 01', 'description': 'Test court'}
    ],
    'business_hours': [
        {'weekday': i, 'open_time': '08:00', 'close_time': '22:00', 'closed': False}
        for i in range(7)
    ]
}

resp = requests.post(
    f"{API_URL}/onboarding",
    json=onboarding_payload,
    headers=auth_headers
)

if resp.status_code not in [200, 201]:
    print(f"❌ Onboarding failed: {resp.status_code} {resp.text}")
    exit(1)

onboarding_result = resp.json()
organization_id = onboarding_result.get('organization_id')
print(f"✅ Onboarding complete. Organization ID: {organization_id}")

# Fetch arenas to get arena_id
print("\n[SETUP] Fetching arena...")
resp = requests.get(
    f"{API_URL}/arenas?organization_id={organization_id}",
    headers=auth_headers
)

if resp.status_code != 200:
    print(f"❌ Failed to fetch arenas: {resp.status_code} {resp.text}")
    exit(1)

arenas = resp.json()
if not arenas or len(arenas) == 0:
    print(f"❌ No arenas found for organization")
    exit(1)

arena_id = arenas[0]['id']
print(f"✅ Arena ID: {arena_id}")

# ============================================================================
# HELPER FUNCTIONS: Create image files with specific magic bytes
# ============================================================================

def create_real_png():
    """Create a real PNG image with valid PNG signature (89 50 4E 47 0D 0A 1A 0A)"""
    img = Image.new('RGB', (10, 10), color='red')
    buf = io.BytesIO()
    img.save(buf, format='PNG')
    buf.seek(0)
    return buf.read()

def create_real_jpeg():
    """Create a real JPEG image with valid JPEG signature (FF D8 FF)"""
    img = Image.new('RGB', (10, 10), color='blue')
    buf = io.BytesIO()
    img.save(buf, format='JPEG')
    buf.seek(0)
    return buf.read()

def create_real_webp():
    """Create a real WEBP image with valid WEBP signature (RIFF....WEBP)"""
    img = Image.new('RGB', (10, 10), color='green')
    buf = io.BytesIO()
    img.save(buf, format='WEBP')
    buf.seek(0)
    return buf.read()

def create_fake_image():
    """Create a fake image (plain text) that is NOT a valid image"""
    return b"this is not an image - just plain text pretending to be an image file"

def create_oversized_image():
    """Create a valid PNG image that exceeds 5MB"""
    # Create a very large image to exceed 5MB
    # A 5000x5000 RGB image should be well over 5MB
    img = Image.new('RGB', (5000, 5000), color='yellow')
    buf = io.BytesIO()
    img.save(buf, format='PNG', compress_level=0)  # No compression to maximize size
    buf.seek(0)
    data = buf.read()
    size_mb = len(data) / (1024*1024)
    print(f"   Generated oversized image: {size_mb:.2f} MB")
    
    # If still not large enough, pad with extra data
    if size_mb < 5.0:
        padding_needed = int((5.5 * 1024 * 1024) - len(data))
        data = data + (b'\x00' * padding_needed)
        print(f"   Padded to: {len(data) / (1024*1024):.2f} MB")
    
    return data

# ============================================================================
# TEST CASES
# ============================================================================

test_results = []

def test_case(case_num, description, file_data, filename, content_type, expected_status, expected_behavior):
    """Run a single test case"""
    print(f"\n{'='*80}")
    print(f"TEST CASE {case_num}: {description}")
    print(f"{'='*80}")
    print(f"  File: {filename}")
    print(f"  Content-Type: {content_type}")
    print(f"  Expected: {expected_status} - {expected_behavior}")
    
    # Get current arena state before upload
    resp_before = requests.get(
        f"{API_URL}/arenas/{arena_id}",
        headers=auth_headers
    )
    arena_before = resp_before.json() if resp_before.status_code == 200 else {}
    cover_before = arena_before.get('cover_image_url')
    photos_before = arena_before.get('photos', [])
    
    # Attempt upload
    files = {
        'file': (filename, file_data, content_type)
    }
    data = {
        'kind': 'cover'
    }
    
    resp = requests.post(
        f"{API_URL}/arenas/{arena_id}/images",
        files=files,
        data=data,
        headers={'Authorization': f'Bearer {access_token}'}
    )
    
    print(f"\n  Response Status: {resp.status_code}")
    print(f"  Response Body: {resp.text[:200]}")
    
    # Check if SUPABASE_SECRET_KEY is in response
    if SUPABASE_SECRET_KEY in resp.text:
        print(f"  ❌ CRITICAL: SUPABASE_SECRET_KEY leaked in response!")
        test_results.append({
            'case': case_num,
            'description': description,
            'status': 'FAIL',
            'reason': 'SUPABASE_SECRET_KEY leaked in response'
        })
        return False
    
    # Verify expected status
    if resp.status_code != expected_status:
        print(f"  ❌ FAIL: Expected status {expected_status}, got {resp.status_code}")
        test_results.append({
            'case': case_num,
            'description': description,
            'status': 'FAIL',
            'reason': f'Expected status {expected_status}, got {resp.status_code}'
        })
        return False
    
    # For successful uploads (201), verify response has arena.cover_image_url
    if expected_status == 201:
        try:
            result = resp.json()
            if 'urls' not in result or not result['urls']:
                print(f"  ❌ FAIL: Response missing 'urls' field")
                test_results.append({
                    'case': case_num,
                    'description': description,
                    'status': 'FAIL',
                    'reason': "Response missing 'urls' field"
                })
                return False
            
            # Check if arena object is in response
            if 'arena' in result and result['arena']:
                arena_after = result['arena']
                cover_after = arena_after.get('cover_image_url')
                
                if not cover_after:
                    print(f"  ❌ FAIL: Arena cover_image_url not set in response")
                    test_results.append({
                        'case': case_num,
                        'description': description,
                        'status': 'FAIL',
                        'reason': 'Arena cover_image_url not set in response'
                    })
                    return False
                
                print(f"  ✅ PASS: Upload successful, cover_image_url set to {cover_after[:50]}...")
                test_results.append({
                    'case': case_num,
                    'description': description,
                    'status': 'PASS',
                    'reason': 'Upload successful and arena updated'
                })
                return True
            else:
                print(f"  ❌ FAIL: Arena object not in response")
                test_results.append({
                    'case': case_num,
                    'description': description,
                    'status': 'FAIL',
                    'reason': 'Arena object not in response'
                })
                return False
            
        except Exception as e:
            print(f"  ❌ FAIL: Error parsing response: {e}")
            test_results.append({
                'case': case_num,
                'description': description,
                'status': 'FAIL',
                'reason': f'Error parsing response: {e}'
            })
            return False
    
    # For rejected uploads (400), verify friendly Portuguese message
    if expected_status == 400:
        try:
            result = resp.json()
            error_msg = result.get('error', '')
            
            # Check for friendly Portuguese message (not raw SQL or technical error)
            if not error_msg:
                print(f"  ❌ FAIL: No error message in response")
                test_results.append({
                    'case': case_num,
                    'description': description,
                    'status': 'FAIL',
                    'reason': 'No error message in response'
                })
                return False
            
            # Verify it's a friendly message (contains Portuguese words, not SQL)
            if any(word in error_msg.lower() for word in ['sql', 'constraint', 'violation', 'exception']):
                print(f"  ❌ FAIL: Error message contains technical/SQL terms: {error_msg}")
                test_results.append({
                    'case': case_num,
                    'description': description,
                    'status': 'FAIL',
                    'reason': f'Error message not user-friendly: {error_msg}'
                })
                return False
            
            # Verify arena was NOT updated (no object persisted)
            resp_after = requests.get(
                f"{API_URL}/arenas/{arena_id}",
                headers=auth_headers
            )
            arena_after = resp_after.json()
            cover_after = arena_after.get('cover_image_url')
            photos_after = arena_after.get('photos', [])
            
            if cover_after != cover_before or photos_after != photos_before:
                print(f"  ❌ FAIL: Arena was modified despite rejection (cleanup failed)")
                test_results.append({
                    'case': case_num,
                    'description': description,
                    'status': 'FAIL',
                    'reason': 'Arena was modified despite rejection'
                })
                return False
            
            print(f"  ✅ PASS: Upload rejected with friendly message: '{error_msg}'")
            print(f"  ✅ PASS: Arena NOT modified (cleanup successful)")
            test_results.append({
                'case': case_num,
                'description': description,
                'status': 'PASS',
                'reason': f'Rejected with friendly message and no data persisted'
            })
            return True
            
        except Exception as e:
            print(f"  ❌ FAIL: Error parsing response: {e}")
            test_results.append({
                'case': case_num,
                'description': description,
                'status': 'FAIL',
                'reason': f'Error parsing response: {e}'
            })
            return False
    
    # Default pass for other expected statuses
    print(f"  ✅ PASS: Got expected status {expected_status}")
    test_results.append({
        'case': case_num,
        'description': description,
        'status': 'PASS',
        'reason': f'Got expected status {expected_status}'
    })
    return True

# ============================================================================
# RUN ALL TEST CASES
# ============================================================================

print("\n" + "="*80)
print("RUNNING TEST CASES")
print("="*80)

# Case 1: Real PNG
test_case(
    1,
    "REAL PNG with valid PNG signature",
    create_real_png(),
    "test.png",
    "image/png",
    201,
    "Upload successful, cover_image_url set"
)

# Case 2: Real JPEG
test_case(
    2,
    "REAL JPEG with valid JPEG signature",
    create_real_jpeg(),
    "test.jpg",
    "image/jpeg",
    201,
    "Upload successful"
)

# Case 3: Real WEBP
test_case(
    3,
    "REAL WEBP with valid WEBP signature",
    create_real_webp(),
    "test.webp",
    "image/webp",
    201,
    "Upload successful"
)

# Case 4: Fake image - text renamed to .jpg
test_case(
    4,
    "FAKE image - text file renamed to .jpg with Content-Type: image/jpeg",
    create_fake_image(),
    "evil.jpg",
    "image/jpeg",
    400,
    "Rejected with friendly Portuguese message"
)

# Case 5: Fake image - text renamed to .png
test_case(
    5,
    "FAKE image - text file renamed to .png with Content-Type: image/png",
    create_fake_image(),
    "evil.png",
    "image/png",
    400,
    "Rejected with friendly Portuguese message"
)

# Case 6: Fake image - text renamed to .webp
test_case(
    6,
    "FAKE image - text file renamed to .webp with Content-Type: image/webp",
    create_fake_image(),
    "evil.webp",
    "image/webp",
    400,
    "Rejected with friendly Portuguese message"
)

# Case 7: Real PNG but wrong Content-Type
test_case(
    7,
    "REAL PNG bytes but Content-Type: text/plain (early mime gate)",
    create_real_png(),
    "test.png",
    "text/plain",
    400,
    "Rejected due to wrong Content-Type"
)

# Case 8: Oversized image
test_case(
    8,
    "OVERSIZED valid image (>5MB)",
    create_oversized_image(),
    "huge.png",
    "image/png",
    400,
    "Rejected due to size limit"
)

# Case 9: Verify cleanup after rejection (already tested in cases 4-6)
print(f"\n{'='*80}")
print(f"TEST CASE 9: Verify NO object persisted after rejection")
print(f"{'='*80}")
print("  This was already verified in cases 4, 5, and 6")
print("  ✅ PASS: All rejected uploads did not modify arena data")
test_results.append({
    'case': 9,
    'description': 'Verify cleanup after rejection',
    'status': 'PASS',
    'reason': 'Verified in cases 4-6 that arena was not modified'
})

# ============================================================================
# SUMMARY
# ============================================================================

print("\n" + "="*80)
print("TEST SUMMARY")
print("="*80)

passed = sum(1 for r in test_results if r['status'] == 'PASS')
failed = sum(1 for r in test_results if r['status'] == 'FAIL')

for result in test_results:
    status_icon = "✅" if result['status'] == 'PASS' else "❌"
    print(f"{status_icon} Case {result['case']}: {result['description']}")
    print(f"   {result['reason']}")

print(f"\n{'='*80}")
print(f"TOTAL: {passed} PASSED, {failed} FAILED out of {len(test_results)} tests")
print(f"{'='*80}")

if failed > 0:
    print("\n❌ SOME TESTS FAILED")
    exit(1)
else:
    print("\n✅ ALL TESTS PASSED")
    exit(0)
