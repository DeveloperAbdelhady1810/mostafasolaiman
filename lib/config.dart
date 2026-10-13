/// Base URL for mostafa-solaiman.online's API. Change this if pointing the
/// app at a different teacher's platform (the same /api/assistant/* surface
/// exists identically on every LearnQuad-lineage platform on this account).
const String apiBaseUrl = 'https://mostafa-solaiman.online/api';

/// Prefix every generated student QR code starts with (see
/// resources/views/student/dashboard.blade.php on the web platform:
/// QrCode::generate('LQ-' . str_pad(student_number, 6, '0', STR_PAD_LEFT))).
const String qrCodePrefix = 'LQ-';

/// Rotating QR shown by the new Mostafa Solaiman student app:
/// `MSQ1:{student_no}:{counter}:{mac as 18 hex}`. It can only be verified by the
/// server (the secret never leaves the student's phone), via /assistant/attendance/bulk.
const String rotatingQrPrefix = 'MSQ1:';
