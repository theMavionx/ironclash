// PROTOTYPE - NOT FOR PRODUCTION
// Question: Is petting a 2D cat with mouse satisfying for 15+ minutes?
// Date: 2026-03-26

using UnityEngine;

/// <summary>
/// Core petting interaction controller. Handles mouse input, detects petting
/// zones, calculates stroke direction/speed, and triggers cat reactions + feedback.
///
/// This is THE system we're testing. If moving the mouse over a cat doesn't
/// feel good, the entire game concept fails.
/// </summary>
public class PettingController : MonoBehaviour
{
    [Header("References")]
    public Camera mainCamera;
    public PrototypeCat currentCat;
    public PettingFeedback feedback;

    [Header("Cursor")]
    public Texture2D handOpenCursor;
    public Texture2D handClosedCursor;
    public Vector2 cursorHotspot = new Vector2(16, 16);

    [Header("Petting Detection")]
    public float minStrokeSpeed = 0.5f;     // below this = hovering, not petting
    public float maxStrokeSpeed = 15f;       // above this = too fast, reduced effect
    public float optimalSpeedMin = 2f;       // sweet spot lower bound
    public float optimalSpeedMax = 8f;       // sweet spot upper bound
    public float petCooldown = 0.3f;         // seconds between pet triggers per zone
    public LayerMask pettingLayerMask;

    // Stroke tracking
    private Vector2 _lastMouseWorldPos;
    private Vector2 _strokeDirection;
    private float _strokeSpeed;
    private bool _isOverCat;
    private bool _isPetting;
    private PettingZone _currentZone;
    private float _zoneCooldownTimer;

    // Metrics (for prototype report)
    private int _totalPets;
    private int _lovedPets;
    private int _dislikedPets;
    private float _sessionTime;
    private float _timeSpentPetting;

    private void Start()
    {
        if (mainCamera == null)
            mainCamera = Camera.main;
    }

    private void Update()
    {
        _sessionTime += Time.deltaTime;

        Vector2 mouseWorldPos = mainCamera.ScreenToWorldPoint(Input.mousePosition);
        _strokeDirection = mouseWorldPos - _lastMouseWorldPos;
        _strokeSpeed = _strokeDirection.magnitude / Time.deltaTime;

        // Detect what's under cursor
        var hit = Physics2D.OverlapPoint(mouseWorldPos, pettingLayerMask);
        PettingZone hitZone = hit != null ? hit.GetComponent<PettingZone>() : null;

        bool wasOverCat = _isOverCat;
        _isOverCat = hitZone != null;

        // Cursor state
        UpdateCursor();

        // Zone tracking
        if (hitZone != _currentZone)
        {
            _currentZone = hitZone;
            _zoneCooldownTimer = 0f;
        }

        // Petting logic
        _isPetting = _isOverCat
                     && Input.GetMouseButton(0)
                     && _strokeSpeed >= minStrokeSpeed;

        if (_isPetting)
        {
            _timeSpentPetting += Time.deltaTime;
            _zoneCooldownTimer -= Time.deltaTime;

            if (_zoneCooldownTimer <= 0f && _currentZone != null)
            {
                // Calculate speed quality
                float speedQuality = CalculateSpeedQuality(_strokeSpeed);

                // Trigger pet on cat
                var reaction = currentCat.ReceivePet(
                    _currentZone,
                    _strokeDirection.normalized,
                    _strokeSpeed
                );

                // Trigger feedback
                if (feedback != null)
                {
                    feedback.PlayPetFeedback(
                        mouseWorldPos,
                        reaction,
                        speedQuality,
                        _currentZone.zoneType
                    );
                }

                // Metrics
                _totalPets++;
                if (reaction == ZoneReaction.Loved) _lovedPets++;
                if (reaction == ZoneReaction.Disliked) _dislikedPets++;

                _zoneCooldownTimer = petCooldown;
            }
        }

        _lastMouseWorldPos = mouseWorldPos;
    }

    /// <summary>
    /// Returns 0-1 quality based on stroke speed.
    /// Optimal speed range = 1.0, too slow or too fast = lower.
    /// </summary>
    private float CalculateSpeedQuality(float speed)
    {
        if (speed < minStrokeSpeed) return 0f;
        if (speed >= optimalSpeedMin && speed <= optimalSpeedMax) return 1f;
        if (speed < optimalSpeedMin)
            return Mathf.InverseLerp(minStrokeSpeed, optimalSpeedMin, speed);
        // speed > optimalSpeedMax
        return Mathf.InverseLerp(maxStrokeSpeed, optimalSpeedMax, speed);
    }

    private void UpdateCursor()
    {
        if (_isPetting && handClosedCursor != null)
            Cursor.SetCursor(handClosedCursor, cursorHotspot, CursorMode.Auto);
        else if (_isOverCat && handOpenCursor != null)
            Cursor.SetCursor(handOpenCursor, cursorHotspot, CursorMode.Auto);
        else
            Cursor.SetCursor(null, Vector2.zero, CursorMode.Auto);
    }

    // Prototype metrics for report
    private void OnGUI()
    {
        GUILayout.BeginArea(new Rect(10, 10, 300, 200));
        GUILayout.Label($"Cat: {currentCat.catName}");
        GUILayout.Label($"Happiness: {currentCat.happiness:F1} / {currentCat.maxHappiness}");
        GUILayout.Label($"Trust: {currentCat.trustLevel:F1} / {currentCat.maxTrust}");
        GUILayout.Label($"Session: {_sessionTime:F0}s | Petting: {_timeSpentPetting:F0}s");
        GUILayout.Label($"Pets: {_totalPets} (loved: {_lovedPets}, disliked: {_dislikedPets})");
        GUILayout.Label($"Stroke speed: {_strokeSpeed:F1}");
        if (_currentZone != null)
            GUILayout.Label($"Zone: {_currentZone.zoneType} ({_currentZone.reaction})");
        GUILayout.EndArea();
    }
}
