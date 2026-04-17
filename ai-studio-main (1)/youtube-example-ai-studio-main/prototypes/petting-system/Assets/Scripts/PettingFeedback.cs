// PROTOTYPE - NOT FOR PRODUCTION
// Question: Is petting a 2D cat with mouse satisfying for 15+ minutes?
// Date: 2026-03-26

using UnityEngine;

/// <summary>
/// Handles all juice and feedback for petting interactions:
/// - Heart particles on loved zones
/// - Purr sound with intensity
/// - Screen shake (subtle) on disliked zones
/// - Floating text feedback
/// </summary>
public class PettingFeedback : MonoBehaviour
{
    [Header("Particles")]
    public ParticleSystem heartParticles;
    public ParticleSystem sparkleParticles;
    public ParticleSystem annoyedParticles; // small puff for disliked

    [Header("Audio")]
    public AudioSource purrAudioSource;
    public AudioClip purrClip;
    public AudioClip happyMeowClip;
    public AudioClip annoyedMeowClip;

    [Header("Audio Tuning")]
    public float purrFadeSpeed = 3f;
    public float maxPurrVolume = 0.6f;
    public float purrPitchVariation = 0.1f;

    [Header("Screen Shake")]
    public float shakeIntensity = 0.05f;
    public float shakeDuration = 0.2f;

    private float _targetPurrVolume;
    private float _shakeTimer;
    private Vector3 _originalCameraPos;
    private Camera _cam;

    private void Start()
    {
        _cam = Camera.main;
        if (_cam != null)
            _originalCameraPos = _cam.transform.position;

        if (purrAudioSource != null && purrClip != null)
        {
            purrAudioSource.clip = purrClip;
            purrAudioSource.loop = true;
            purrAudioSource.volume = 0f;
            purrAudioSource.Play();
        }
    }

    private void Update()
    {
        // Smooth purr volume
        if (purrAudioSource != null)
        {
            purrAudioSource.volume = Mathf.Lerp(
                purrAudioSource.volume,
                _targetPurrVolume,
                Time.deltaTime * purrFadeSpeed
            );
            _targetPurrVolume = Mathf.Lerp(_targetPurrVolume, 0f, Time.deltaTime * 2f);
        }

        // Camera shake recovery
        if (_shakeTimer > 0f && _cam != null)
        {
            _shakeTimer -= Time.deltaTime;
            var offset = Random.insideUnitCircle * shakeIntensity * (_shakeTimer / shakeDuration);
            _cam.transform.position = _originalCameraPos + new Vector3(offset.x, offset.y, 0f);
        }
        else if (_cam != null)
        {
            _cam.transform.position = _originalCameraPos;
        }
    }

    public void PlayPetFeedback(Vector2 position, ZoneReaction reaction, float speedQuality, PettingZoneType zone)
    {
        switch (reaction)
        {
            case ZoneReaction.Loved:
                EmitHearts(position, 3 + Mathf.FloorToInt(speedQuality * 3));
                EmitSparkles(position, 2);
                SetPurrIntensity(0.8f + speedQuality * 0.2f);
                if (happyMeowClip != null && Random.value < 0.15f)
                    PlayOneShot(happyMeowClip, 0.4f);
                break;

            case ZoneReaction.Neutral:
                EmitHearts(position, 1);
                SetPurrIntensity(0.3f + speedQuality * 0.2f);
                break;

            case ZoneReaction.Disliked:
                EmitAnnoyed(position);
                ShakeCamera();
                SetPurrIntensity(0f);
                if (annoyedMeowClip != null)
                    PlayOneShot(annoyedMeowClip, 0.5f);
                break;
        }
    }

    private void EmitHearts(Vector2 pos, int count)
    {
        if (heartParticles == null) return;
        heartParticles.transform.position = pos;
        heartParticles.Emit(count);
    }

    private void EmitSparkles(Vector2 pos, int count)
    {
        if (sparkleParticles == null) return;
        sparkleParticles.transform.position = pos;
        sparkleParticles.Emit(count);
    }

    private void EmitAnnoyed(Vector2 pos)
    {
        if (annoyedParticles == null) return;
        annoyedParticles.transform.position = pos;
        annoyedParticles.Emit(5);
    }

    private void SetPurrIntensity(float intensity)
    {
        _targetPurrVolume = intensity * maxPurrVolume;
        if (purrAudioSource != null)
        {
            purrAudioSource.pitch = 1f + Random.Range(-purrPitchVariation, purrPitchVariation);
        }
    }

    private void ShakeCamera()
    {
        _shakeTimer = shakeDuration;
    }

    private void PlayOneShot(AudioClip clip, float volume)
    {
        if (purrAudioSource != null)
            purrAudioSource.PlayOneShot(clip, volume);
    }
}
