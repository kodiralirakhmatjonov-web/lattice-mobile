# Hotel Import publish gate v2

Publishing no longer depends on room-specific photos or an automatically extracted price.

Required to publish:
- source identity;
- at least one selected general hotel photo (room/bathroom-only media does not satisfy this gate);
- at least one confirmed room type.

All valid recognized room types are still persisted. Room/bathroom photos remain optional enrichment. If the nominated cover fails but another general hotel photo is stored, Hotels Cloud promotes a fallback general hotel image to cover automatically.

No D1 migration is required.
