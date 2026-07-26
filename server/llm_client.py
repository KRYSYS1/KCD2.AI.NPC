"""LLM client using OpenAI-compatible API."""

import logging
from openai import AsyncOpenAI

from server.config import LLMConfig

logger = logging.getLogger(__name__)


class LLMClient:
    def __init__(self, config: LLMConfig):
        self.config = config
        self._missing_api_key = self._requires_api_key() and not (config.api_key or "").strip()
        self.client = AsyncOpenAI(
            base_url=config.api_url,
            # The OpenAI SDK raises during construction when api_key is empty.
            # Keep the server/UI alive and report the config problem on use.
            api_key=config.api_key or "missing-api-key",
        )

    def _requires_api_key(self) -> bool:
        api_url = (self.config.api_url or "").lower()
        return "localhost" not in api_url and "127.0.0.1" not in api_url

    async def generate(
        self,
        system_prompt: str,
        messages: list[dict[str, str]],
        image_b64: str | None = None,
    ) -> str:
        """Generate a response from the LLM.

        Args:
            system_prompt: The system prompt with NPC context.
            messages: Conversation history as list of {"role": ..., "content": ...}.
            image_b64: Optional base64 JPEG screenshot ("зрение ИИ"). Attached to
                the LAST user message in OpenAI multimodal format. History dicts
                are not mutated (base64 must never leak into saved conversations).
                If the model rejects the vision request, we retry once text-only.

        Returns:
            The generated text response.
        """
        if self._missing_api_key:
            raise RuntimeError(
                "LLM API key is not set. Open http://127.0.0.1:4999, enter your Groq/OpenAI API key, "
                "or configure local Ollama in config.json."
            )
        sys_text = system_prompt
        if image_b64:
            sys_text += (
                "\nA live image of the current scene (from the traveler's viewpoint) is attached "
                "to his last message. You are standing right there and can see the same things: "
                "react in character to what is visible. Never mention screenshots, images or pictures."
            )
        full_messages: list = [{"role": "system", "content": sys_text}]
        full_messages.extend(messages)
        if image_b64:
            for i in range(len(full_messages) - 1, -1, -1):
                if full_messages[i].get("role") == "user":
                    txt = str(full_messages[i].get("content") or "")
                    full_messages[i] = {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": txt},
                            {"type": "image_url",
                             "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}},
                        ],
                    }
                    break

        try:
            response = await self.client.chat.completions.create(
                model=self.config.model,
                messages=full_messages,
                max_tokens=self.config.max_tokens,
                temperature=self.config.temperature,
            )
            text = response.choices[0].message.content or ""
            return text.strip()
        except Exception as e:
            if image_b64:
                # Модель без vision (или картинка отвергнута) — не роняем чат,
                # повторяем запрос без изображения.
                logger.warning(f"LLM vision request failed ({e}); retrying text-only")
                return await self.generate(system_prompt, messages)
            logger.error(f"LLM request failed: {e}")
            raise
