begin read only;
select created_at::date from storage.objects where bucket_id='pinka-covers' and name='13e991a8-b762-43ff-8f49-160ea4da1556/28a69cc0-9238-4506-88c8-0a8850ffeca2.png';
select count(*) filter (where slot_id is not null) slot, count(*) filter (where qr_token_once is not null) once from pinka_finance.tickets;
select count(*) from pinka_finance.public_contributions pc join pinka_finance.campaigns c on c.id=pc.campaign_id where c.type='tickets';
rollback;
