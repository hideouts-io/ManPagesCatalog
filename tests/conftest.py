from hypothesis import settings

settings.register_profile("ci", max_examples=100)
settings.register_profile("thorough", max_examples=500)
settings.load_profile("ci")
