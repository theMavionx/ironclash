// PROTOTYPE - NOT FOR PRODUCTION
// Question: Is petting a 2D cat with mouse satisfying for 15+ minutes?
// Date: 2026-03-26

using UnityEngine;

/// <summary>
/// Minimal cat data and state for the petting prototype.
/// Hardcoded values — no config files, no ScriptableObjects.
/// </summary>
public class PrototypeCat : MonoBehaviour
{
    [Header("State")]
    public float happiness = 20f;
    public float trustLevel = 0f;
    public string catName = "Mурка";

    [Header("Tuning — hardcoded for prototype")]
    public float happinessGainOnLoved = 5f;
    public float happinessGainOnNeutral = 2f;
    public float happinessLossOnDisliked = 3f;
    public float trustGainOnLoved = 3f;
    public float trustGainOnNeutral = 1f;
    public float happinessDecayPerSecond = 0.1f;
    public float maxHappiness = 100f;
    public float maxTrust = 100f;

    [Header("References")]
    public SpriteRenderer catSprite;
    public Animator catAnimator;

    // Current visual state
    private float _purrIntensity;
    private bool _isTurningAway;
    private float _turnAwayTimer;

    private void Update()
    {
        // Passive happiness decay
        happiness = Mathf.Max(0f, happiness - happinessDecayPerSecond * Time.deltaTime);

        // Turn away recovery
        if (_isTurningAway)
        {
            _turnAwayTimer -= Time.deltaTime;
            if (_turnAwayTimer <= 0f)
            {
                _isTurningAway = false;
                if (catAnimator != null)
                    catAnimator.SetBool("TurnAway", false);
            }
        }

        // Purr intensity fades
        _purrIntensity = Mathf.Lerp(_purrIntensity, 0f, Time.deltaTime * 2f);

        // Update animator
        if (catAnimator != null)
        {
            catAnimator.SetFloat("Happiness", happiness / maxHappiness);
            catAnimator.SetFloat("PurrIntensity", _purrIntensity);
        }

        // Simple sprite color feedback (placeholder for real animations)
        if (catSprite != null)
        {
            float h = happiness / maxHappiness;
            // Happier = warmer color tint
            catSprite.color = Color.Lerp(
                new Color(0.7f, 0.7f, 0.8f), // sad: slightly blue-gray
                Color.white,                    // happy: normal
                h
            );
        }
    }

    /// <summary>
    /// Called by PettingController when player pets a zone on this cat.
    /// Returns the reaction for feedback purposes.
    /// </summary>
    public ZoneReaction ReceivePet(PettingZone zone, Vector2 strokeDirection, float strokeSpeed)
    {
        if (_isTurningAway)
            return ZoneReaction.Disliked;

        var reaction = zone.reaction;

        switch (reaction)
        {
            case ZoneReaction.Loved:
                happiness = Mathf.Min(maxHappiness, happiness + happinessGainOnLoved);
                trustLevel = Mathf.Min(maxTrust, trustLevel + trustGainOnLoved);
                _purrIntensity = 1f;
                break;

            case ZoneReaction.Neutral:
                happiness = Mathf.Min(maxHappiness, happiness + happinessGainOnNeutral);
                trustLevel = Mathf.Min(maxTrust, trustLevel + trustGainOnNeutral);
                _purrIntensity = 0.5f;
                break;

            case ZoneReaction.Disliked:
                happiness = Mathf.Max(0f, happiness - happinessLossOnDisliked);
                _isTurningAway = true;
                _turnAwayTimer = 1.5f;
                if (catAnimator != null)
                    catAnimator.SetBool("TurnAway", true);
                break;
        }

        return reaction;
    }

    public float GetHappinessNormalized() => happiness / maxHappiness;
    public float GetTrustNormalized() => trustLevel / maxTrust;
}
