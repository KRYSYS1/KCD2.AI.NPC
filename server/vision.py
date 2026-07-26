"""Зрение ИИ: скриншот игры для vision-LLM.

Сервер крутится на той же машине, что и игра, поэтому просто снимаем
экран (PIL.ImageGrab), ужимаем и отдаём base64-JPEG. Кадр прикладывается
к последнему сообщению игрока в OpenAI-совместимом multimodal-формате
(llm_client.generate(..., image_b64=...)).

Требуется Pillow (pip install Pillow). Если его нет — молча возвращаем
None, чат продолжает работать текстом.

Ограничение: PIL.ImageGrab снимает рабочий стол. В borderless/windowed
режиме игры кадр честный; в эксклюзивном fullscreen может вернуться
чёрный экран — тогда переключите игру в borderless.
"""

import asyncio
import base64
import io
import logging

logger = logging.getLogger(__name__)

MAX_WIDTH = 1280       # даунскейл до этой ширины (экономия токенов vision)
JPEG_QUALITY = 70


def _grab_sync() -> str | None:
    try:
        from PIL import Image, ImageGrab
    except ImportError:
        logger.warning("[vision] Pillow не установлен — скриншоты недоступны (pip install Pillow)")
        return None
    try:
        img = ImageGrab.grab()
    except Exception as exc:
        logger.warning(f"[vision] screen grab failed: {exc}")
        return None
    if img is None:
        return None
    if img.width > MAX_WIDTH:
        new_h = max(1, int(img.height * MAX_WIDTH / img.width))
        img = img.resize((MAX_WIDTH, new_h), Image.LANCZOS)
    buf = io.BytesIO()
    img.convert("RGB").save(buf, format="JPEG", quality=JPEG_QUALITY)
    return base64.b64encode(buf.getvalue()).decode("ascii")


async def capture_b64() -> str | None:
    """Снять скриншот, не блокируя event loop. None при любой проблеме."""
    try:
        return await asyncio.to_thread(_grab_sync)
    except Exception as exc:
        logger.warning(f"[vision] capture failed: {exc}")
        return None
