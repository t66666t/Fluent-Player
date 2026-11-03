package com.example.video_player_app

/** Dedicated process and library; shares only the tested ownership transport. */
class CohereAsrService : QwenAsrService("fluent_cohere_asr", "Cohere")
