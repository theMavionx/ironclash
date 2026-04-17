// PROTOTYPE - NOT FOR PRODUCTION
// Question: Is petting a 2D cat with mouse satisfying for 15+ minutes?
// Date: 2026-03-26

using UnityEngine;

public enum PettingZoneType
{
    Head,
    Ears,
    Chin,
    Cheeks,
    Back,
    Belly,
    Tail,
    Paws
}

public enum ZoneReaction
{
    Loved,    // favorite zone — max happiness, purring
    Neutral,  // ok zone — some happiness
    Disliked  // bad zone — cat turns away
}

/// <summary>
/// Attach to a child collider of the cat. Defines a petting zone area.
/// </summary>
public class PettingZone : MonoBehaviour
{
    public PettingZoneType zoneType;
    public ZoneReaction reaction = ZoneReaction.Neutral;

    [Header("Visual Feedback")]
    public Color gizmoColor = Color.green;
    public float zoneRadius = 0.3f;

    private void OnDrawGizmos()
    {
        Gizmos.color = gizmoColor;
        Gizmos.DrawWireSphere(transform.position, zoneRadius);
    }
}
