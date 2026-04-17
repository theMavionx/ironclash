// PROTOTYPE - NOT FOR PRODUCTION
// Question: Is petting a 2D cat with mouse satisfying for 15+ minutes?
// Date: 2026-03-26

using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// Simple UI overlay showing happiness bar, trust bar, and cat name.
/// Uses Unity UI Canvas with Image fills.
/// </summary>
public class PrototypeHUD : MonoBehaviour
{
    [Header("References")]
    public PrototypeCat cat;

    [Header("UI Elements")]
    public Image happinessBarFill;
    public Image trustBarFill;
    public Text catNameText;
    public Text happinessText;
    public Text trustText;

    [Header("Colors")]
    public Color happinessLowColor = new Color(0.6f, 0.6f, 0.8f);   // blue-gray
    public Color happinessHighColor = new Color(1f, 0.8f, 0.9f);     // warm pink
    public Color trustLowColor = new Color(0.8f, 0.8f, 0.8f);       // gray
    public Color trustHighColor = new Color(0.9f, 0.7f, 1f);        // soft purple

    [Header("Animation")]
    public float barSmoothSpeed = 5f;

    private float _displayedHappiness;
    private float _displayedTrust;

    private void Update()
    {
        if (cat == null) return;

        float targetHappiness = cat.GetHappinessNormalized();
        float targetTrust = cat.GetTrustNormalized();

        _displayedHappiness = Mathf.Lerp(_displayedHappiness, targetHappiness, Time.deltaTime * barSmoothSpeed);
        _displayedTrust = Mathf.Lerp(_displayedTrust, targetTrust, Time.deltaTime * barSmoothSpeed);

        if (happinessBarFill != null)
        {
            happinessBarFill.fillAmount = _displayedHappiness;
            happinessBarFill.color = Color.Lerp(happinessLowColor, happinessHighColor, _displayedHappiness);
        }

        if (trustBarFill != null)
        {
            trustBarFill.fillAmount = _displayedTrust;
            trustBarFill.color = Color.Lerp(trustLowColor, trustHighColor, _displayedTrust);
        }

        if (catNameText != null)
            catNameText.text = cat.catName;

        if (happinessText != null)
            happinessText.text = $"Happiness: {cat.happiness:F0}";

        if (trustText != null)
            trustText.text = $"Trust: {cat.trustLevel:F0}";
    }
}
